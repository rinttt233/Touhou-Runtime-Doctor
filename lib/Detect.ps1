# ============================================================================
#  Detect.ps1 -- 体检引擎
#
#  设计要点：
#   1. 依赖清单来自 PE 解析结果，不是硬编码猜测。th06~th09 是 DirectX 8 作品
#      （导入 d3d8.dll），th10+ 才是 DirectX 9；混为一谈会修不好。
#   2. VC2005/2008 走 WinSxS 并行程序集，VC2010+ 才是 system32/SysWOW64 实体
#      文件。只查 system32 会对 VC2005/2008 产生假阴性。
#   3. 32 位进程在 64 位系统上加载的是 SysWOW64，不是 System32。检查依赖时
#      必须按目标 exe 的位数选目录，否则会"补错位数"。
#   4. 每个 finding 都带 Evidence（证据），报告里可复核，不做无依据断言。
# ============================================================================
Set-StrictMode -Version 2.0

# 东方各作品 -> 引擎世代（决定需要 DirectX 8 还是 DirectX 9）
$script:TH_ENGINE = @{
    'th06'   = @{ Engine = 'dx8'; Name = '东方红魔乡 ~ the Embodiment of Scarlet Devil' }
    'th07'   = @{ Engine = 'dx8'; Name = '东方妖妖梦 ~ Perfect Cherry Blossom' }
    'th08'   = @{ Engine = 'dx8'; Name = '东方永夜抄 ~ Imperishable Night' }
    'th09'   = @{ Engine = 'dx8'; Name = '东方花映塚 ~ Phantasmagoria of Flower View' }
    'th095'  = @{ Engine = 'dx9'; Name = '东方文花帖 ~ Shoot the Bullet' }
    'th10'   = @{ Engine = 'dx9'; Name = '东方风神录 ~ Mountain of Faith' }
    'th11'   = @{ Engine = 'dx9'; Name = '东方地灵殿 ~ Subterranean Animism' }
    'th12'   = @{ Engine = 'dx9'; Name = '东方星莲船 ~ Undefined Fantastic Object' }
    'th123'  = @{ Engine = 'dx9'; Name = '东方非想天则 ~ Scarlet Weather Rhapsody 资料片' }
    'th13'   = @{ Engine = 'dx9'; Name = '东方神灵庙 ~ Ten Desires' }
    'th14'   = @{ Engine = 'dx9'; Name = '东方辉针城 ~ Double Dealing Character' }
    'th15'   = @{ Engine = 'dx9'; Name = '东方绀珠传 ~ Legacy of Lunatic Kingdom' }
    'th16'   = @{ Engine = 'dx9'; Name = '东方天空璋 ~ Hidden Star in Four Seasons' }
    'th17'   = @{ Engine = 'dx9'; Name = '东方鬼形兽 ~ Wily Beast and Weakest Creature' }
    'th18'   = @{ Engine = 'dx9'; Name = '东方虹龙洞 ~ Unconnected Marketeers' }
    'th19'   = @{ Engine = 'dx9'; Name = '东方兽王园 ~ Unfinished Dream of All Living Ghost' }
    'th105'  = @{ Engine = 'dx9'; Name = '东方绯想天 ~ Scarlet Weather Rhapsody' }
    'th125'  = @{ Engine = 'dx9'; Name = '东方文花帖DS ~ Double Spoiler' }
    'th128'  = @{ Engine = 'dx9'; Name = '妖精大战争 ~ Great Fairy Wars' }
    'th143'  = @{ Engine = 'dx9'; Name = '弹幕天邪鬼 ~ Impossible Spell Card' }
    'th155'  = @{ Engine = 'dx9'; Name = '东方凭依华 ~ Antinomy of Common Flowers' }
    'th165'  = @{ Engine = 'dx9'; Name = '秘封噩梦日记 ~ Violet Detector' }
    'th185'  = @{ Engine = 'dx9'; Name = '东方刚欲异闻 ~ Sunken Fossil World' }
}

# DLL -> 提供它的修复包能力（用于把"缺哪个 DLL"翻译成"装哪个包"）
$script:DLL_PROVIDER = @{
    'd3d8.dll'         = @{ Cap = 'directx8-runtime';      Pkg = 'DX9_REDIST_JUN2010'; Why = 'DirectX 8 的 Direct3D 组件，Windows 10/11 精简版常缺失' }
    'd3d8thk.dll'      = @{ Cap = 'directx8-runtime';      Pkg = 'DX9_REDIST_JUN2010'; Why = 'Direct3D 8 内核 thunk' }
    'd3d9.dll'         = @{ Cap = 'directx9-legacy';       Pkg = 'DX9_REDIST_JUN2010'; Why = 'Direct3D 9 核心' }
    'ddraw.dll'        = @{ Cap = 'directx-legacy-full';   Pkg = 'DX9_REDIST_JUN2010'; Why = 'DirectDraw，th06 的 16 位色彩模式依赖它' }
    'd3dim.dll'        = @{ Cap = 'directx-legacy-full';   Pkg = 'DX9_REDIST_JUN2010'; Why = 'Direct3D 立即模式（DX 6/7）' }
    'd3dim700.dll'     = @{ Cap = 'directx-legacy-full';   Pkg = 'DX9_REDIST_JUN2010'; Why = 'Direct3D 立即模式 7.0' }
    'd3drm.dll'        = @{ Cap = 'directx-legacy-full';   Pkg = 'DX9_REDIST_JUN2010'; Why = 'Direct3D 保留模式' }
    'dinput.dll'       = @{ Cap = 'directx-legacy-full';   Pkg = 'DX9_REDIST_JUN2010'; Why = 'DirectInput（旧版）' }
    'dinput8.dll'      = @{ Cap = 'directx9-legacy';       Pkg = 'DX9_REDIST_JUN2010'; Why = 'DirectInput 8' }
    'dsound.dll'       = @{ Cap = 'directx9-legacy';       Pkg = 'DX9_REDIST_JUN2010'; Why = 'DirectSound' }
    'dsound3d.dll'     = @{ Cap = 'directx-legacy-full';   Pkg = 'DX9_REDIST_JUN2010'; Why = 'DirectSound3D' }
    'dplayx.dll'       = @{ Cap = 'directx-legacy-full';   Pkg = 'DX9_REDIST_JUN2010'; Why = 'DirectPlay' }
    'xinput1_3.dll'    = @{ Cap = 'xinput-1.3';            Pkg = 'DX9_REDIST_JUN2010'; Why = 'XInput 手柄支持' }
    'xinput9_1_0.dll'  = @{ Cap = 'xinput-1.3';            Pkg = 'DX9_REDIST_JUN2010'; Why = 'XInput 9.1.0' }
    'xaudio2_7.dll'    = @{ Cap = 'xaudio2-2.7';           Pkg = 'DX9_REDIST_JUN2010'; Why = 'XAudio2 2.7' }
    'msvcr71.dll'      = @{ Cap = 'vc2003-x86';            Pkg = $null;                Why = 'Visual C++ 2003 (.NET 1.1 时代) 运行库' }
    'msvcr80.dll'      = @{ Cap = 'vc2005-x86';            Pkg = 'VC2005_X86';         Why = 'Visual C++ 2005 运行库' }
    'msvcp80.dll'      = @{ Cap = 'vc2005-x86';            Pkg = 'VC2005_X86';         Why = 'Visual C++ 2005 运行库' }
    'msvcr90.dll'      = @{ Cap = 'vc2008-x86';            Pkg = 'VC2008_X86';         Why = 'Visual C++ 2008 运行库' }
    'msvcp90.dll'      = @{ Cap = 'vc2008-x86';            Pkg = 'VC2008_X86';         Why = 'Visual C++ 2008 运行库' }
    'msvcr100.dll'     = @{ Cap = 'vc2010-x86';            Pkg = 'VC2010_X86';         Why = 'Visual C++ 2010 运行库' }
    'msvcp100.dll'     = @{ Cap = 'vc2010-x86';            Pkg = 'VC2010_X86';         Why = 'Visual C++ 2010 运行库' }
    'msvcr110.dll'     = @{ Cap = 'vc2012-x86';            Pkg = 'VC2012_X86';         Why = 'Visual C++ 2012 运行库' }
    'msvcp110.dll'     = @{ Cap = 'vc2012-x86';            Pkg = 'VC2012_X86';         Why = 'Visual C++ 2012 运行库' }
    'msvcr120.dll'     = @{ Cap = 'vc2013-x86';            Pkg = 'VC2013_X86';         Why = 'Visual C++ 2013 运行库' }
    'msvcp120.dll'     = @{ Cap = 'vc2013-x86';            Pkg = 'VC2013_X86';         Why = 'Visual C++ 2013 运行库' }
    'vcruntime140.dll' = @{ Cap = 'vc140-x86';             Pkg = 'VC2015_2022_X86';    Why = 'Visual C++ 2015-2022 运行库' }
    'vcruntime140_1.dll' = @{ Cap = 'vc140-x86';           Pkg = 'VC2015_2022_X86';    Why = 'Visual C++ 2015-2022 运行库 (x64 异常处理)' }
    'msvcp140.dll'     = @{ Cap = 'vc140-x86';             Pkg = 'VC2015_2022_X86';    Why = 'Visual C++ 2015-2022 运行库' }
}

# 各 VC 版本的检测定义：DLL 名 + WinSxS 程序集前缀 + 注册表名称匹配
$script:VC_DEFS = @(
    @{ Ver = '2005';     Disp = 'Visual C++ 2005';        Dlls = @('msvcr80.dll','msvcp80.dll');                       SxS = @('microsoft.vc80.crt');  Reg = 'Visual C\+\+ 2005' }
    @{ Ver = '2008';     Disp = 'Visual C++ 2008';        Dlls = @('msvcr90.dll','msvcp90.dll');                       SxS = @('microsoft.vc90.crt');  Reg = 'Visual C\+\+ 2008' }
    @{ Ver = '2010';     Disp = 'Visual C++ 2010';        Dlls = @('msvcr100.dll','msvcp100.dll');                     SxS = @('microsoft.vc100.crt'); Reg = 'Visual C\+\+ 2010' }
    @{ Ver = '2012';     Disp = 'Visual C++ 2012';        Dlls = @('msvcr110.dll','msvcp110.dll');                     SxS = @('microsoft.vc110.crt'); Reg = 'Visual C\+\+ 2012' }
    @{ Ver = '2013';     Disp = 'Visual C++ 2013';        Dlls = @('msvcr120.dll','msvcp120.dll');                     SxS = @('microsoft.vc120.crt'); Reg = 'Visual C\+\+ 2013' }
    @{ Ver = '2015+';    Disp = 'Visual C++ 2015-2022';   Dlls = @('vcruntime140.dll','msvcp140.dll','vcruntime140_1.dll'); SxS = @('microsoft.vc140.crt'); Reg = 'Visual C\+\+ (2015|2017|2019|2022|v14)' }
)

# ---------------------------------------------------------------------------
#  基础工具
# ---------------------------------------------------------------------------
function New-TrdFinding {
    <#
    .SYNOPSIS
        构造一条体检结论。
    .PARAMETER Severity
        Blocker 无法启动 / High 功能受损 / Medium 体验问题 / Low 建议 / Pass 正常
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Category,
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)]
        [ValidateSet('Blocker', 'High', 'Medium', 'Low', 'Pass')]
        [string]$Severity,
        [string]$Detail = '',
        [string[]]$Evidence = @(),
        [string]$FixId = $null,
        [string]$FixHint = $null,
        [string]$NeedsPackage = $null
    )

    return [PSCustomObject]@{
        Id           = $Id
        Category     = $Category
        Title        = $Title
        Severity     = $Severity
        Detail       = $Detail
        Evidence     = @($Evidence)
        FixId        = $FixId
        FixHint      = $FixHint
        NeedsPackage = $NeedsPackage
    }
}

function Test-TrdHasProp {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $false }
    return ($Object.PSObject.Properties.Name -contains $Name)
}

function Get-TrdRegUninstallEntries {
    <#
    .SYNOPSIS
        枚举 32/64 位卸载项（VC 运行库的主要注册表证据来源）。
    .DESCRIPTION
        必须【显式】按注册表视图分别读取，不能依赖进程默认视图：
        VC++ 运行库是分位数注册的，x64 那份在 64 位视图、x86 那份在 32 位视图。
        在 64 位系统上以 32 位 PowerShell 运行时，默认视图就是 32 位视图，
        读 HKLM\SOFTWARE\... 只能拿到 x86 的安装记录，而 64 位视图【完全够不到】，
        x64 运行库于是集体"消失"，导致误报"VC 运行库缺失"并触发一次
        毫无必要的重装。旧实现从 32 位进程跑时只能看到约 130 条（x86 那半），
        现在两个视图合起来是 108(x64) + 130(x86) = 238 条。

        这里也不再写 WOW6432Node 字面量。注意：写它并不会出错 ——
        实测注册表 API 对 WOW6432Node 是幂等的（Registry32 视图下
        'SOFTWARE\WOW6432Node' 与 'SOFTWARE' 是同一个键）。不用字面量
        只是为了让"读哪个视图"由参数说清楚，而不是藏在路径拼写里。
    #>
    $out  = New-Object System.Collections.ArrayList
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'

    $views = @('Native', 'X86')
    if (-not $script:TRD.Is64OS) { $views = @('Native') }   # 32 位系统只有一个视图

    foreach ($v in $views) {
        $k = $null
        try {
            $k = Open-TrdRegSubKey -RegPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall' -View $v
            if (-not $k) { continue }
            foreach ($sub in @($k.GetSubKeyNames())) {
                $sk = $null
                try {
                    $sk = $k.OpenSubKey($sub, $false)
                    if (-not $sk) { continue }
                    $opt  = [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames
                    $name = [string]$sk.GetValue('DisplayName', '', $opt)
                    if (-not $name) { continue }
                    $ver  = [string]$sk.GetValue('DisplayVersion', '', $opt)
                    $id   = $v + '|' + $sub
                    if ($seen.Add($id)) {
                        $null = $out.Add([PSCustomObject]@{
                            Name    = $name
                            Version = $ver
                            Key     = $sub
                            View    = $(if ($v -eq 'X86') { '32位' } else { '64位' })
                        })
                    }
                } catch {
                } finally {
                    if ($sk) { try { $sk.Close() } catch { } }
                }
            }
        } catch {
        } finally {
            if ($k) { try { $k.Close() } catch { } }
        }
    }
    return $out
}

# ---------------------------------------------------------------------------
#  目标定位
# ---------------------------------------------------------------------------
function Find-TrdTouhouGames {
    <#
    .SYNOPSIS
        搜索本机上的东方 Project 游戏目录。
    .DESCRIPTION
        判定标准：目录中存在 <thXX>.exe（th06~th19，含 .5 小数作）。扫描范围：
        指定路径 -> 工具所在盘 -> 常见游戏盘根目录下两层。
    .PARAMETER ExtraRoots
        额外的起始搜索目录。
    #>
    [CmdletBinding()]
    param(
        [string[]]$ExtraRoots = @(),
        [int]$MaxDepth = 3
    )

    $roots = New-Object System.Collections.ArrayList
    foreach ($r in $ExtraRoots) { if ($r -and (Test-Path -LiteralPath $r)) { $null = $roots.Add($r) } }

    # 常见游戏根目录
    $guess = @('D:\game', 'E:\game', 'C:\game', 'D:\games', 'E:\games',
               "$env:USERPROFILE\Desktop", "$env:USERPROFILE\Documents", "$env:USERPROFILE\Downloads")
    foreach ($g in $guess) { if (Test-Path -LiteralPath $g) { $null = $roots.Add($g) } }
    # 所有固定磁盘根目录
    try {
        foreach ($d in [System.IO.DriveInfo]::GetDrives()) {
            if ($d.DriveType -eq 'Fixed' -and $d.IsReady) { $null = $roots.Add($d.RootDirectory.FullName) }
        }
    } catch { }

    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $found = New-Object System.Collections.ArrayList

    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        # 用 Get-TrdChildDirectory 而不是 Get-ChildItem -Depth：
        # -Depth 是 PowerShell 5.0 才有的参数，Win7 默认的 PS2 / WMF3 上会
        # 直接报"找不到与参数名称 Depth 匹配的参数"。
        $dirs = Get-TrdChildDirectory -Path $root -MaxDepth $MaxDepth
        foreach ($d in @($dirs)) {
            if (-not $seen.Add($d.FullName)) { continue }
            $exes = @(Get-ChildItem -LiteralPath $d.FullName -File -Filter 'th*.exe' -ErrorAction SilentlyContinue |
                      Where-Object { $_.Name -match '^(th\d{2,3})\.exe$' })
            if ($exes.Count -eq 0) { continue }

            $main = $exes | Where-Object { $_.Name -notmatch '^(custom|replayview)$' } |
                    Sort-Object { $_.Name.Length } | Select-Object -First 1
            $id = [System.IO.Path]::GetFileNameWithoutExtension($main.Name)

            $eng = 'unknown'; $disp = $id
            if ($script:TH_ENGINE.ContainsKey($id)) {
                $eng = $script:TH_ENGINE[$id].Engine
                $disp = $script:TH_ENGINE[$id].Name
            }

            $null = $found.Add([PSCustomObject]@{
                Id          = $id
                Folder      = $d.FullName
                MainExe     = $main.FullName
                LauncherExe = $(if (Test-Path -LiteralPath (Join-Path $d.FullName 'vpatch.exe')) { Join-Path $d.FullName 'vpatch.exe' } else { $null })
                Engine      = $eng
                DisplayName = $disp
                ExeCount    = $exes.Count
                FolderName  = $d.Name
            })
        }
    }

    return @($found | Sort-Object Id)
}

# ---------------------------------------------------------------------------
#  VC 运行库状态
# ---------------------------------------------------------------------------
function Get-TrdVcRuntimeState {
    <#
    .SYNOPSIS
        判定每个 VC 运行库版本、每种位数的安装状态。
    .DESCRIPTION
        三路取证，避免单一来源误判：
          a) 注册表卸载项
          b) 磁盘 DLL（32 位系统目录 / 64 位系统目录，按位数区分）
          c) WinSxS 并行程序集（VC2005/2008 唯一可靠的落地证据）
        只要 (b) 或 (c) 成立即认为该版本该位数可用。
    #>
    [CmdletBinding()]
    param()

    $w = $env:windir
    $sx = Join-Path $w 'WinSxS'
    $uninstall = Get-TrdRegUninstallEntries

    $results = New-Object System.Collections.ArrayList

    foreach ($def in $script:VC_DEFS) {
        $regHits = @($uninstall | Where-Object { $_.Name -match $def.Reg })
        $regVersions = @($regHits | ForEach-Object { $_.Version } | Sort-Object -Unique)

        foreach ($arch in @('x86', 'x64')) {
            # 目录与"是否适用"统一由 Get-TrdSystemDir 决定。
            # 之前的判断依赖 $env:PROCESSOR_ARCHITECTURE，在 64 位系统上用 32 位
            # PowerShell 运行时会得到 "x86"，把 64 位系统误判成 32 位。
            $sysDir = Get-TrdSystemDir -Bitness $arch
            if (-not $sysDir) {
                # 该位数在本机不适用（典型：32 位系统上的 x64）
                $null = $results.Add([PSCustomObject]@{
                    Version = $def.Ver; Display = $def.Disp; Arch = 'x64'
                    Installed = $false; Source = '不适用'
                    Details = @('32 位操作系统，不存在也不需要 x64 运行库')
                    FromRegistry = @(); FromDisk = @(); FromWinSxS = @(); Applicable = $false
                })
                continue
            }

            $fromDisk = New-Object System.Collections.ArrayList
            foreach ($dll in $def.Dlls) {
                $p = Join-Path $sysDir $dll
                if (Test-Path -LiteralPath $p) { $null = $fromDisk.Add($dll) }
            }

            $fromSxS = New-Object System.Collections.ArrayList
            if (Test-Path -LiteralPath $sx) {
                $prefix = if ($arch -eq 'x86') { 'x86_' } else { 'amd64_' }
                foreach ($asmb in $def.SxS) {
                    try {
                        # 不用 -Filter（它与 -LiteralPath 组合不可靠），用显式通配路径
                        $hit = @(Get-ChildItem -Path (Join-Path $sx ($prefix + $asmb + '_*')) -Directory -ErrorAction SilentlyContinue)
                        foreach ($h in $hit) {
                            $v = ($h.Name -split '_')[3]
                            $null = $fromSxS.Add("$asmb ($v)")
                        }
                    } catch { }
                }
            }

            $fromReg = @($regHits | Where-Object { $_.Name -match "x86|x64" -and $_.Name -match $(if ($arch -eq 'x86') { 'x86' } else { 'x64' }) })

            $installed = ($fromDisk.Count -gt 0) -or ($fromSxS.Count -gt 0) -or ($fromReg.Count -gt 0)
            $source = @()
            if ($fromDisk.Count -gt 0) { $source += '磁盘' }
            if ($fromSxS.Count -gt 0)  { $source += 'WinSxS' }
            if ($fromReg.Count -gt 0)  { $source += '注册表' }

            $details = New-Object System.Collections.ArrayList
            if ($fromSxS.Count -gt 0) { $null = $details.Add("并行程序集: " + ($fromSxS -join ', ')) }
            if ($fromDisk.Count -gt 0) { $null = $details.Add("系统目录 DLL: " + ($fromDisk -join ', ')) }
            if ($fromReg.Count -gt 0) { $null = $details.Add("注册表版本: " + (($fromReg | ForEach-Object { $_.Version }) -join ', ')) }
            if (-not $installed) { $null = $details.Add("未在 system32/SysWOW64 或 WinSxS 中找到 " + ($def.Dlls -join '/')) }

            $null = $results.Add([PSCustomObject]@{
                Version       = $def.Ver
                Display       = $def.Disp
                Arch          = $arch
                Installed     = $installed
                Source        = ($source -join '+')
                Details       = @($details)
                FromRegistry  = @($fromReg | ForEach-Object { $_.Version })
                FromDisk      = @($fromDisk)
                FromWinSxS    = @($fromSxS)
                Applicable    = $true
            })
        }
    }

    return $results
}

# ---------------------------------------------------------------------------
#  DirectX 状态
# ---------------------------------------------------------------------------
function Get-TrdDirectXState {
    <#
    .SYNOPSIS
        检查 DirectX 各组件的落地情况，按【位数】分别记录。
    .DESCRIPTION
        目录选择必须走 Get-TrdSystemDir：
          64 位系统：32 位组件在 SysWOW64，64 位组件在 System32
          32 位系统：32 位组件就在 System32，且不存在 64 位目录
        早期版本硬编码 SysWOW64，在 32 位 Windows 上会把所有组件都报成缺失，
        进而把一台完全健康的机器判成"严重"并试图去"修复"它。
    #>
    [CmdletBinding()]
    param()

    $dirX86 = Get-TrdSystemDir -Bitness 'x86'
    $dirX64 = Get-TrdSystemDir -Bitness 'x64'

    $r = [PSCustomObject]@{
        RegVersion     = $null
        InstalledMajor = $null
        X86Dir         = $dirX86
        X64Dir         = $dirX64
        Is64OS         = [bool]$script:TRD.Is64OS
        X86            = @{}     # 32 位系统 DLL 的存在性
        X64            = @{}     # 64 位系统 DLL 的存在性（32 位系统上为空）
        Missing        = @()     # 32 位侧缺失的组件（这才是东方系列关心的）
        Present        = @()
    }

    try {
        $r.RegVersion = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\DirectX' -Name Version -ErrorAction Stop).Version
    } catch { }

    # InstalledVersion 是 REG_BINARY，DX9.0c 的实际字节是 00 00 00 09 00 00 00 00。
    # 两个坑：
    #   1) 它按【大端】存放主版本号，直接用 BitConverter.ToInt32（小端）会得到
    #      150994944 这种荒唐数字。这里按大端逐字节拼。
    #   2) WOW6432Node 是 WOW64 重定向产生的，32 位 Windows 上这个分支根本不存在，
    #      必须回落到普通的 SOFTWARE\Microsoft\DirectX。
    foreach ($k in @('HKLM:\SOFTWARE\WOW6432Node\Microsoft\DirectX',
                     'HKLM:\SOFTWARE\Microsoft\DirectX')) {
        if ($r.InstalledMajor) { break }
        try {
            $iv = @((Get-ItemProperty -Path $k -Name InstalledVersion -ErrorAction Stop).InstalledVersion)
            if ($iv.Count -ge 4) {
                $major = ([int]$iv[0] -shl 24) -bor ([int]$iv[1] -shl 16) -bor ([int]$iv[2] -shl 8) -bor [int]$iv[3]
                # 合理性校验：DirectX 主版本只可能是个小数字，否则视为解析失败
                if ($major -ge 1 -and $major -le 12) { $r.InstalledMajor = $major }
            }
        } catch { }
    }

    # 需要关注的 DirectX 组件清单（含 DX8 与 DX9 两代）
    $watch = @(
        'd3d8.dll', 'd3d8thk.dll', 'd3d9.dll', 'ddraw.dll', 'd3dim.dll',
        'd3dim700.dll', 'd3drm.dll', 'dinput.dll', 'dinput8.dll', 'dsound.dll',
        'd3dx9_24.dll', 'd3dx9_25.dll', 'd3dx9_26.dll', 'd3dx9_27.dll', 'd3dx9_28.dll',
        'd3dx9_29.dll', 'd3dx9_30.dll', 'd3dx9_31.dll', 'd3dx9_32.dll', 'd3dx9_33.dll',
        'd3dx9_34.dll', 'd3dx9_35.dll', 'd3dx9_36.dll', 'D3DX9_37.dll', 'D3DX9_38.dll',
        'D3DX9_39.dll', 'D3DX9_40.dll', 'D3DX9_41.dll', 'D3DX9_42.dll', 'D3DX9_43.dll',
        'D3DCompiler_33.dll', 'D3DCompiler_43.dll', 'D3DCompiler_47.dll',
        'xinput1_3.dll', 'xinput9_1_0.dll', 'XAudio2_7.dll'
    )

    foreach ($n in $watch) {
        $hasX86 = $false
        if ($dirX86) { $hasX86 = Test-Path -LiteralPath (Join-Path $dirX86 $n) }
        $r.X86[$n] = $hasX86

        if ($dirX64) {
            $r.X64[$n] = Test-Path -LiteralPath (Join-Path $dirX64 $n)
        }

        if ($hasX86) { $r.Present += $n } else { $r.Missing += $n }
    }

    return $r
}

# ---------------------------------------------------------------------------
#  PE 依赖解析
# ---------------------------------------------------------------------------
function Test-TrdDebugVariantName {
    <#
    .SYNOPSIS
        判断一个"仅来自字符串线索"的 DLL 名是否为调试版名字，从而应被忽略。
    .DESCRIPTION
        MSVC 工具链的调试版组件在文件名末尾加 d：d3d8.dll -> d3d8d.dll、
        msvcr80.dll -> msvcr80d.dll。发布版程序中这些名字常以字符串形式残留
        （来自库文件里的默认路径或断言文本），运行时并不会被加载。
        判据：形如 xxxd.dll，且去掉末尾的 d 后得到的 xxx.dll 确实存在
        （出现在同一文件的静态导入表里，或能在磁盘上解析到）。
        这样既能滤掉噪音，又不会漏掉真正需要加载的文件。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [string[]]$StaticNames = @(),
        [string]$Bitness = 'x86',
        [string]$GameFolder
    )

    if ($Name -notmatch '^(.+)d\.dll$') { return $false }
    $base = $Matches[1] + '.dll'

    if ($StaticNames -contains $base.ToLower()) { return $true }

    $dirs = @()
    if ($GameFolder) { $dirs = @($GameFolder) }
    $r = Resolve-DependencyPath -Name $base -Bitness $Bitness -ExtraDirs $dirs
    return $r.Found
}

function Resolve-TrdGameDependencies {
    <#
    .SYNOPSIS
        对游戏目录内所有 PE 做导入表解析并逐个落地检查。
    .OUTPUTS
        PSCustomObject: Exes[], Missing[], WrongBitness[], Shadowed[], OkCount, TotalDeps
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$GameFolder,
        [string[]]$SkipFiles = @()
    )

    # 注意：Get-ChildItem 的 -Include 与 -LiteralPath 组合时行为不可靠（会退化成返回全部文件），
    # 曾经因此把 th08.dat / thbgm.dat 这类纯数据文件也当成 PE 去解析，虚报了 6 个"解析失败"。
    # 这里显式按扩展名过滤，不依赖 -Include。
    $peFiles = @(Get-ChildItem -LiteralPath $GameFolder -File -ErrorAction SilentlyContinue |
                 Where-Object { $_.Extension -in '.exe', '.dll' })

    $exes = New-Object System.Collections.ArrayList
    $missing = New-Object System.Collections.ArrayList
    $wrongBits = New-Object System.Collections.ArrayList
    $shadowed = New-Object System.Collections.ArrayList
    $okCount = 0
    $totalDeps = 0

    # 游戏主程序的位数决定"系统目录"该看哪个
    $mainArch = 'x86'
    $main = $peFiles | Where-Object { $_.Name -match '^th\d{2,3}\.exe$' } | Select-Object -First 1
    if (-not $main) { $main = $peFiles | Where-Object { $_.Extension -eq '.exe' } | Select-Object -First 1 }
    if ($main) {
        $mi = Get-PeInfo -Path $main.FullName
        if ($mi.Ok -and $mi.Is64) { $mainArch = 'x64' }
    }

    foreach ($f in $peFiles) {
        if ($SkipFiles -contains $f.Name) { continue }
        $info = Get-PeInfo -Path $f.FullName
        if (-not $info.Ok) {
            $null = $exes.Add([PSCustomObject]@{
                Name = $f.Name; Path = $f.FullName; Arch = 'unknown'; Ok = $false
                Error = $info.Error; Imports = @(); Is64 = $false
            })
            continue
        }

        # 位数与主程序不一致的目录内 DLL —— 0xC000007B 的经典元凶
        if ($f.Extension -eq '.dll' -and $main -and $info.Is64 -ne $mi.Is64 -and -not $mi.Is64) {
            $null = $wrongBits.Add([PSCustomObject]@{
                Name = $f.Name; Path = $f.FullName; Arch = $info.Arch; Expected = $mainArch
            })
        }

        # ---------------------------------------------------------------
        #  依赖来源必须区分对待：
        #   * 静态导入表  = 权威依据。加载器一定会去解析它。
        #   * 二进制字符串 = 仅供启发式的线索。MSVC 的调试版组件以 d 结尾
        #     （d3d8.dll 的调试版叫 d3d8d.dll），这些名字会作为字符串残留在
        #     发布版文件里，但运行时根本不会被加载。
        #  曾经把 d3d8d.dll 报成 Blocker 级缺失 —— 这就是误报的来源。
        # ---------------------------------------------------------------
        $staticDeps  = @($info.Imports    | Where-Object { $_ -match '\.dll$' })
        $stringDeps  = @($info.DllStrings | Where-Object { $_ -match '\.dll$' })
        $staticLower = @($staticDeps | ForEach-Object { $_.ToLower() })

        $allDeps = @(($staticDeps + $stringDeps) | Sort-Object -Unique)

        foreach ($dep in $allDeps) {
            if (Test-IsApiSet -Name $dep) { continue }
            $isStatic = ($staticLower -contains $dep.ToLower())

            # 字符串线索中的调试版名字先剔除，不计入依赖总数
            if (-not $isStatic -and
                (Test-TrdDebugVariantName -Name $dep -StaticNames $staticLower -Bitness $mainArch -GameFolder $GameFolder)) {
                continue
            }
            $totalDeps++

            $res = Resolve-DependencyPath -Name $dep -Bitness $mainArch -ExtraDirs @($GameFolder)

            if (-not $res.Found) {
                $provider = $null
                if ($script:DLL_PROVIDER.ContainsKey($dep.ToLower())) { $provider = $script:DLL_PROVIDER[$dep.ToLower()] }
                $null = $missing.Add([PSCustomObject]@{
                    Dll      = $dep
                    NeededBy = $f.Name
                    Provider = $provider
                    Source   = $(if ($isStatic) { 'Static' } else { 'String' })
                })
            } else {
                $okCount++
                # 目录内本地副本是否遮蔽了系统副本（且更旧）
                $local = Join-Path $GameFolder $dep
                if ((Test-Path -LiteralPath $local) -and $res.FullPath -ne $local) {
                    try {
                        $lv = (Get-Item -LiteralPath $local).VersionInfo.FileVersion
                        $sv = (Get-Item -LiteralPath $res.FullPath).VersionInfo.FileVersion
                        if ($lv -and $sv -and $lv -ne $sv) {
                            $null = $shadowed.Add([PSCustomObject]@{
                                Dll = $dep; Local = $local; LocalVer = $lv
                                SystemPath = $res.FullPath; SystemVer = $sv
                            })
                        }
                    } catch { }
                }
            }
        }

        $null = $exes.Add([PSCustomObject]@{
            Name = $f.Name; Path = $f.FullName; Arch = $info.Arch; Ok = $true
            Error = $null; Imports = @($info.Imports); Is64 = $info.Is64
        })
    }

    return [PSCustomObject]@{
        Exes           = @($exes)
        MainArch       = $mainArch
        MainExe        = $(if ($main) { $main.FullName } else { $null })
        Missing        = @($missing)
        WrongBitness   = @($wrongBits)
        Shadowed       = @($shadowed)
        OkCount        = $okCount
        TotalDeps      = $totalDeps
    }
}

# ---------------------------------------------------------------------------
#  环境与兼容性
# ---------------------------------------------------------------------------
function Get-TrdCompatFlags {
    <#
    .SYNOPSIS
        读取用户级 AppCompatFlags\Layers（按 exe 全路径）。
    #>
    param([string[]]$ExePaths)
    $key = 'HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers'
    $out = @{}
    try {
        $p = Get-ItemProperty -Path $key -ErrorAction Stop
        foreach ($prop in $p.PSObject.Properties) {
            if ($prop.Name -like 'PS*') { continue }
            $out[$prop.Name] = $prop.Value
        }
    } catch { }
    return $out
}

function Get-TrdDisplayScaling {
    <#
    .SYNOPSIS
        取当前 DPI 缩放百分比。
    #>
    $dpi = 96
    try {
        $v = (Get-ItemProperty 'HKCU:\Control Panel\Desktop\WindowMetrics' -Name AppliedDPI -ErrorAction SilentlyContinue).AppliedDPI
        if ($v) { $dpi = [int]$v }
    } catch { }
    return [PSCustomObject]@{
        Dpi     = $dpi
        Percent = [Math]::Round(($dpi / 96.0) * 100)
    }
}

function Test-TrdMotW {
    <#
    .SYNOPSIS
        检测文件是否带"来自 Internet"标记（Zone.Identifier），该标记会触发
        SmartScreen / Defender 拦截汉化版 exe。
    #>
    param([string]$Path)
    try {
        $ads = Get-Item -LiteralPath $Path -Stream 'Zone.Identifier' -ErrorAction Stop
        if ($ads) { return $true }
    } catch { }
    return $false
}

function Get-TrdFontState {
    <#
    .SYNOPSIS
        通过注册表字体表判断日文字体是否存在（日文原版作品需要）。
    #>
    param()
    $fonts = @{}
    foreach ($hive in @('HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts',
                        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows NT\CurrentVersion\Fonts')) {
        try {
            $p = Get-ItemProperty -Path $hive -ErrorAction Stop
            foreach ($prop in $p.PSObject.Properties) {
                if ($prop.Name -like 'PS*') { continue }
                $fonts[$prop.Name] = $prop.Value
            }
        } catch { }
    }
    $gothic = @($fonts.Keys | Where-Object { $_ -match 'Gothic|ゴシック' }).Count -gt 0
    $mincho = @($fonts.Keys | Where-Object { $_ -match 'Mincho|明朝' }).Count -gt 0
    return [PSCustomObject]@{ HasGothic = $gothic; HasMincho = $mincho; Count = $fonts.Count }
}

function Get-TrdDotNetState {
    <#
    .SYNOPSIS
        读取 .NET Framework 版本（Locale Emulator 需要 4.x）。
    #>
    $r = [PSCustomObject]@{ V4Full = $null; V4Release = 0; Has4x = $false; Has35 = $false }
    try {
        $v = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -ErrorAction Stop)
        $r.V4Full = $v.Version
        $r.V4Release = [int]$v.Release
        $r.Has4x = $true
    } catch { }
    try {
        $null = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v3.5' -ErrorAction Stop
        $r.Has35 = $true
    } catch { }
    return $r
}

function Get-TrdDefenderState {
    $r = [PSCustomObject]@{ Available = $false; RealTimeOn = $false; Excluded = @() }
    try {
        $pref = Get-MpPreference -ErrorAction Stop
        $r.Available = $true
        $r.Excluded = @($pref.ExclusionPath)
        $st = Get-MpComputerStatus -ErrorAction SilentlyContinue
        if ($st) { $r.RealTimeOn = [bool]$st.RealTimeProtectionEnabled }
    } catch { }
    return $r
}

# ===========================================================================
#  驱动 / 设备 / 服务 / 冲突软件 / 游戏文件完整性
#
#  这一整块针对的是"运行库全都装好了，游戏还是跑不起来"的那类原因。
#  它们不属于 DLL 依赖问题，靠 PE 解析永远查不出来，但同样会导致黑屏、
#  闪退、无声、卡死。典型场景：
#    * 显卡驱动没装（跑在"Microsoft 基本显示适配器"上）-> 无法建立 3D 设备
#    * Windows Audio 服务被"优化"工具关掉 -> DirectSound 初始化失败直接退出
#    * 显卡驱动不再提供 640x480 模式 -> 全屏初始化失败
#    * 第三方杀软把汉化版 exe 当木马隔离 -> 文件消失或内容被改写
#    * 变速齿轮 / 各种覆盖层注入游戏进程 -> 崩溃
# ===========================================================================

function Get-TrdGpuState {
    <#
    .SYNOPSIS
        采集显卡与驱动状态，含"是否只是通用显示适配器"这一关键判据。
    .DESCRIPTION
        ConfigManagerErrorCode 是最有价值的单一字段：
          0    = 设备工作正常
          非 0 = 驱动有问题（未安装 / 已停止 / 资源冲突），此时 3D 加速基本不可用
        另外要识别"通用显示适配器"：名字里带"基本显示适配器 / Basic Display"
        说明装的是 Windows 自带的兜底驱动，没有任何厂商 3D 加速。
    #>
    [CmdletBinding()]
    param()

    $list = New-Object System.Collections.ArrayList
    $raw = Get-TrdWmiObject -ClassName 'Win32_VideoController'
    foreach ($g in @($raw)) {
        if (-not $g) { continue }

        $name = [string]$g.Name
        $errCode = 0
        try { $errCode = [int]$g.ConfigManagerErrorCode } catch { }
        $status = [string]$g.Status

        # Windows 自带的兜底驱动，没有厂商 3D 加速
        $isBasic = ($name -match 'Microsoft Basic Display|Basic Render|基本显示|标准 VGA|Standard VGA|Microsoft 基本')

        # DriverDate 的返回类型取决于拿到它的途径，必须两种都处理：
        #   Get-CimInstance -> 已经反序列化成 DateTime 对象
        #   Get-WmiObject   -> 原始的 WMI 日期字符串，如 20240608000000.000000+000
        # 只按字符串处理会让 CIM 路径下日期直接丢失，连带"驱动过旧"检查静默失效。
        $drvDate = $null
        try {
            $raw = $g.DriverDate
            if ($raw -is [datetime]) {
                $drvDate = $raw
            } elseif ($raw) {
                $s = [string]$raw
                if ($s -match '^\d{14}') {
                    $drvDate = [Management.ManagementDateTimeConverter]::ToDateTime($s)
                } else {
                    # 有些提供程序直接给本地化日期串（如 "2024/6/8 8:00:00"）。
                    # 先按当前区域解析，再退回不变区域，避免因区域设置差异丢失日期。
                    try { $drvDate = [datetime]::Parse($s) }
                    catch { $drvDate = [datetime]::Parse($s, [System.Globalization.CultureInfo]::InvariantCulture) }
                }
            }
        } catch { }

        $drvAgeYears = $null
        if ($drvDate) { $drvAgeYears = [Math]::Round(((Get-Date) - $drvDate).TotalDays / 365.25, 1) }

        $null = $list.Add([PSCustomObject]@{
            Name            = $name
            DriverVersion   = [string]$g.DriverVersion
            DriverDate      = $drvDate
            DriverAgeYears  = $drvAgeYears
            ErrorCode       = $errCode
            Status          = $status
            IsBasicAdapter  = $isBasic
            AdapterRAM_MB   = $(try { [Math]::Round([double]$g.AdapterRAM / 1MB, 0) } catch { $null })
            VideoProcessor  = [string]$g.VideoProcessor
            Vendor          = [string]$g.AdapterCompatibility
            CurWidth        = $(try { [int]$g.CurrentHorizontalResolution } catch { 0 })
            CurHeight       = $(try { [int]$g.CurrentVerticalResolution } catch { 0 })
            CurRefresh      = $(try { [int]$g.CurrentRefreshRate } catch { 0 })
        })
    }

    return @($list)
}

function Get-TrdDisplayModes {
    <#
    .SYNOPSIS
        枚举显卡驱动报告的全部显示模式，检查老游戏需要的低分辨率是否存在。
    .DESCRIPTION
        东方永夜抄默认请求 640x480 全屏。绝大多数现代驱动会自动缩放，
        但部分较新的驱动已经不再列出 640x480/800x600 这些模式，
        全屏初始化就会失败（表现为黑屏几秒后退出，或直接回到桌面）。
        这里通过 EnumDisplaySettings 真实枚举，而不是靠猜。
        需要临时编译一小段 C#（Add-Type）；在受限语言模式下会失败，
        此时返回 Supported=$null 表示"无法检测"，不当作故障。
    #>
    [CmdletBinding()]
    param()

    $r = [PSCustomObject]@{
        Detected      = $false
        ModeCount     = 0
        Has640x480    = $null
        Has800x600    = $null
        MinWidth      = $null
        MinHeight     = $null
        SampleModes   = @()
        Reason        = $null
    }

    try {
        if (-not ('TrdDisplayModes' -as [type])) {
            $cs = @'
using System;
using System.Runtime.InteropServices;
public class TrdDisplayModes {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Ansi)]
    public struct DEVMODE {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
        public short dmSpecVersion; public short dmDriverVersion; public short dmSize;
        public short dmDriverExtra; public int dmFields;
        public int dmPositionX; public int dmPositionY;
        public int dmDisplayOrientation; public int dmDisplayFixedOutput;
        public short dmColor; public short dmDuplex; public short dmYResolution;
        public short dmTTOption; public short dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
        public short dmLogPixels; public int dmBitsPerPel; public int dmPelsWidth;
        public int dmPelsHeight; public int dmDisplayFlags; public int dmDisplayFrequency;
        public int dmICMMethod; public int dmICMIntent; public int dmMediaType;
        public int dmDitherType; public int dmReserved1; public int dmReserved2;
        public int dmPanningWidth; public int dmPanningHeight;
    }
    [DllImport("user32.dll", CharSet = CharSet.Ansi)]
    public static extern bool EnumDisplaySettings(string deviceName, int modeNum, ref DEVMODE devMode);
    public static string[] List() {
        var res = new System.Collections.Generic.List<string>();
        var dm = new DEVMODE();
        dm.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
        int i = 0;
        while (EnumDisplaySettings(null, i, ref dm)) {
            res.Add(dm.dmPelsWidth + "x" + dm.dmPelsHeight);
            i++;
            if (i > 4000) break;
        }
        return res.ToArray();
    }
}
'@
            Add-Type -TypeDefinition $cs -ErrorAction Stop
        }

        $modes = @([TrdDisplayModes]::List())
        $r.Detected = $true

        # 驱动会把同一个分辨率在不同刷新率下重复列出。
        # 按"宽x高"去重后再统计，否则会报出"371 个模式"这种没有意义的数字。
        $distinct = @($modes | Sort-Object -Unique)
        $r.ModeCount = $distinct.Count

        if ($distinct.Count -gt 0) {
            $wh = @()
            foreach ($m in $distinct) {
                $p = $m -split 'x'
                if ($p.Count -eq 2) { $wh += [PSCustomObject]@{ W = [int]$p[0]; H = [int]$p[1] } }
            }
            $r.Has640x480 = (@($wh | Where-Object { $_.W -eq 640 -and $_.H -eq 480 }).Count -gt 0)
            $r.Has800x600 = (@($wh | Where-Object { $_.W -eq 800 -and $_.H -eq 600 }).Count -gt 0)
            if ($wh.Count -gt 0) {
                $r.MinWidth  = ($wh | Measure-Object -Property W -Minimum).Minimum
                $r.MinHeight = ($wh | Measure-Object -Property H -Minimum).Minimum
            }
            $r.SampleModes = @($distinct | Select-Object -First 12)
        }
    } catch {
        $r.Reason = $_.Exception.Message
    }

    return $r
}

function Get-TrdAudioState {
    <#
    .SYNOPSIS
        采集音频设备与音频服务状态。
    .DESCRIPTION
        东方系列通过 DirectSound 初始化音频。以下两种情况会让游戏在启动阶段
        就直接失败或卡死（表现常是"点了没反应"或"黑屏后消失"）：
          * 系统里没有任何音频输出设备（虚拟机、被禁用、驱动缺失）
          * Windows Audio 服务没有运行（被"系统优化"工具关掉是常见原因）
        注意：msiserver 之类的服务处于 Stopped 属于正常（手动触发），
        但 Audiosrv 是自动启动的，停着就说明有问题。
    #>
    [CmdletBinding()]
    param()

    $devices = New-Object System.Collections.ArrayList
    $raw = Get-TrdWmiObject -ClassName 'Win32_SoundDevice'
    foreach ($d in @($raw)) {
        if (-not $d) { continue }
        $errCode = 0
        try { $errCode = [int]$d.ConfigManagerErrorCode } catch { }
        $null = $devices.Add([PSCustomObject]@{
            Name      = [string]$d.Name
            Status    = [string]$d.Status
            ErrorCode = $errCode
        })
    }

    $svcStatus = $null
    $svcStart  = $null
    try {
        $s = Get-Service -Name 'Audiosrv' -ErrorAction Stop
        $svcStatus = [string]$s.Status
        $svcStart  = [string]$s.StartType
    } catch { }

    return [PSCustomObject]@{
        Devices        = @($devices)
        DeviceCount    = $devices.Count
        BadDevices     = @($devices | Where-Object { $_.ErrorCode -ne 0 -or ($_.Status -and $_.Status -ne 'OK') })
        ServiceStatus  = $svcStatus
        ServiceStart   = $svcStart
        ServiceRunning = ($svcStatus -eq 'Running')
    }
}

function Get-TrdInstallPolicyState {
    <#
    .SYNOPSIS
        检查 Windows Installer 服务与安装策略，确认"还能不能装运行库"。
    .DESCRIPTION
        工具再怎么修，最终都要靠 MSI 安装包来补 VC / DirectX 运行库。
        如果 MSI 服务被禁用，或组策略里设了 DisableMSI，安装会静默失败：
        安装程序返回一个非 0 退出码，用户看到的是"修复没生效"。
        这里提前把这类环境问题查出来。
        关键点：msiserver 处于 Stopped 是【正常】的（手动触发），
        只有 StartType=Disabled 或策略禁用才是真问题。
    #>
    [CmdletBinding()]
    param()

    $r = [PSCustomObject]@{
        MsiStatus      = $null
        MsiStartType   = $null
        MsiDisabled    = $false
        PolicyDisable  = $null
        PolicyBlocked  = $false
        TrustedInstallerStartType = $null
    }

    try {
        $s = Get-Service -Name 'msiserver' -ErrorAction Stop
        $r.MsiStatus = [string]$s.Status
        $r.MsiStartType = [string]$s.StartType
        $r.MsiDisabled = ($r.MsiStartType -eq 'Disabled')
    } catch { }

    try {
        $s2 = Get-Service -Name 'TrustedInstaller' -ErrorAction Stop
        $r.TrustedInstallerStartType = [string]$s2.StartType
    } catch { }

    # 组策略：DisableMSI = 1(只禁用户安装) / 2(全部禁止) / 0(允许)
    foreach ($k in @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\Installer',
                     'HKCU:\SOFTWARE\Policies\Microsoft\Windows\Installer')) {
        try {
            $v = Get-ItemProperty -Path $k -Name 'DisableMSI' -ErrorAction Stop
            if ($null -ne $v.DisableMSI) {
                $r.PolicyDisable = [int]$v.DisableMSI
                if ($r.PolicyDisable -eq 2) { $r.PolicyBlocked = $true }
            }
        } catch { }
    }

    return $r
}

function Get-TrdSecurityProducts {
    <#
    .SYNOPSIS
        列出已注册的安全软件（含第三方杀软）。
    .DESCRIPTION
        SecurityCenter2 比只看 Defender 更重要：国内常见的第三方杀软
        （尤其对汉化版 exe）误报隔离率很高，而且它们的排除项设置方式
        各不相同。发现第三方杀软时给出明确的提示，比事后排查"文件怎么没了"
        有效得多。
        SecurityCenter2 是 Windows XP SP2 以后都有的命名空间，
        但在 Server 版本上可能不存在，因此失败时返回空列表而不是报错。
    #>
    [CmdletBinding()]
    param()

    $list = New-Object System.Collections.ArrayList
    $cimOk = Get-Command -Name 'Get-CimInstance' -ErrorAction SilentlyContinue
    $raw = $null
    try {
        if ($cimOk) {
            $raw = Get-CimInstance -Namespace 'root\SecurityCenter2' -ClassName 'AntiVirusProduct' -ErrorAction Stop
        } else {
            $raw = Get-WmiObject -Namespace 'root\SecurityCenter2' -Class 'AntiVirusProduct' -ErrorAction Stop
        }
    } catch { }

    foreach ($p in @($raw)) {
        if (-not $p) { continue }
        $n = [string]$p.displayName
        $state = 0
        try { $state = [int]$p.productState } catch { }
        $isDefender = ($n -match 'Windows Defender|Microsoft Defender')
        $null = $list.Add([PSCustomObject]@{
            Name       = $n
            ProductState = $state
            IsDefender = $isDefender
        })
    }

    return [PSCustomObject]@{
        Products         = @($list)
        HasThirdParty    = (@($list | Where-Object { -not $_.IsDefender }).Count -gt 0)
        ThirdPartyNames  = @($list | Where-Object { -not $_.IsDefender } | ForEach-Object { $_.Name })
    }
}

function Get-TrdConflictingProcesses {
    <#
    .SYNOPSIS
        查找已知会与老游戏冲突的常驻进程。
    .DESCRIPTION
        三类典型冲突：
          * 变速/加速工具：向目标进程注入代码改时钟，老引擎常直接崩溃。
            这也是汉化圈里"游戏莫名闪退"的高频原因。
          * 画面覆盖层/监控工具：挂 D3D/DirectDraw 钩子，抢占渲染管线。
          * 输入法进程：中文输入法在独占全屏下会导致输入丢失或焦点异常，
            东方系列尤其明显（社区通用做法是启动前切英文输入法）。
    #>
    [CmdletBinding()]
    param()

    # 每项： 正则 -> 类别
    $known = @(
        @{ Pat = 'Speeder|变速齿轮|GameSpeed|CheatEngine|cheatengine|ArtMoney|FPE|GM9'; Cat = '变速/修改工具' }
        @{ Pat = 'RTSS|RivaTuner|MSIAfterburner|Afterburner|Fraps|Bandicam|Dxtory|OBS|Action!|NvidiaShare|ReShade|SpecialK'; Cat = '画面覆盖层/录像/监控' }
        @{ Pat = 'ctfmon|ChsIME|Sogou|QQPinyin|BaiduPinyin|SGTool|Youdao|QQInput|Wetype|Weasel|Rime'; Cat = '输入法' }
        @{ Pat = 'Discord|Overwolf|GameBar|XboxGaming|RazerSynapse|LogiOverlay|Nahimic|SonicStudio'; Cat = '游戏内覆盖层' }
        @{ Pat = 'vJoy|DS4Windows|BetterJoy|ViGEm|ScpServer|XOutput'; Cat = '虚拟手柄驱动' }
    )

    $found = New-Object System.Collections.ArrayList
    $procs = @()
    try { $procs = @(Get-Process -ErrorAction SilentlyContinue | Select-Object -ExpandProperty ProcessName -Unique) } catch { }

    foreach ($p in $procs) {
        foreach ($k in $known) {
            if ($p -match $k.Pat) {
                $null = $found.Add([PSCustomObject]@{ Process = $p; Category = $k.Cat })
                break
            }
        }
    }

    return @($found)
}

function Get-TrdGameDataState {
    <#
    .SYNOPSIS
        检查游戏本体数据文件是否齐全、体量是否可疑。
    .DESCRIPTION
        运行库全对、驱动也正常，游戏仍可能在读取资源时失败。常见原因：
          * 数据文件被反病毒软件当作病毒"清除"（内容被清空但文件名还在）
          * 从压缩包解出时被中断，文件被截断
          * 汉化补丁替换不完整
        这里不做精确哈希（版本差异大，硬编码会误报），只判断：
          * 该有的数据文件在不在
          * 体量是否明显不合理（0 字节、或主数据文件小于 1MB）
        这类"文件在但内容不对"的故障，光看文件是否存在是查不出来的。
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$GameFolder)

    $mainDat = @()
    $bgmDat  = @()
    $suspect = @()
    $missing = @()

    foreach ($f in @(Get-ChildItem -LiteralPath $GameFolder -File -ErrorAction SilentlyContinue)) {
        if ($f.Name -match '^th\d{2,3}\.dat$') { $mainDat += $f }
        elseif ($f.Name -match '^thbgm\.dat$') { $bgmDat += $f }
    }

    if ($mainDat.Count -eq 0) {
        # 这里不用 th??.dat 这种带问号的通配写法：报告按 GBK 输出，
        # 问号会让用户误以为是自己文件里的乱码。
        $missing += '主数据文件（th06~th19 对应的 th<编号>.dat，游戏本体资源包）'
    } else {
        foreach ($f in $mainDat) {
            if ($f.Length -lt 1MB) {
                $suspect += "$($f.Name) 只有 $([Math]::Round($f.Length/1KB,1)) KB —— 明显被截断或被安全软件清空"
            }
        }
    }

    foreach ($f in $bgmDat) {
        if ($f.Length -lt 1MB) {
            $suspect += "$($f.Name) 只有 $([Math]::Round($f.Length/1KB,1)) KB —— 明显被截断或被安全软件清空"
        }
    }

    $totalMB = 0
    foreach ($f in @($mainDat + $bgmDat)) { $totalMB += $f.Length }
    $totalMB = [Math]::Round($totalMB / 1MB, 0)

    return [PSCustomObject]@{
        MainDat      = @($mainDat | ForEach-Object { $_.Name })
        BgmDat       = @($bgmDat | ForEach-Object { $_.Name })
        MainDatMB    = [Math]::Round((@($mainDat | Measure-Object Length -Sum).Sum) / 1MB, 1)
        Missing      = @($missing)
        Suspect      = @($suspect)
        TotalDataMB  = $totalMB
    }
}

function Get-TrdVirtualStoreState {
    <#
    .SYNOPSIS
        检查游戏是否落在 Program Files 下而写入被 UAC 虚拟化重定向。
    .DESCRIPTION
        老游戏把存档与配置写在自身目录。当游戏装在 Program Files 下且没有
        以管理员运行、也没开"以管理员身份运行此程序"时，Windows 会把写入
        重定向到 %LOCALAPPDATA%\VirtualStore。结果是：
        游戏读不到自己刚写的配置，或者存档出现在一个谁也想不到的位置。
        表现是"设置改完没用""存档不保存"，很容易误判成游戏 bug。
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$GameFolder)

    $r = [PSCustomObject]@{
        UnderProgramFiles = $false
        VirtualStorePath  = $null
        VirtualStoreHit   = $false
    }

    $pf = @()
    if ($env:ProgramFiles) { $pf += $env:ProgramFiles }
    if (${env:ProgramFiles(x86)}) { $pf += ${env:ProgramFiles(x86)} }

    foreach ($p in $pf) {
        if ($p -and $GameFolder.StartsWith($p, [StringComparison]::OrdinalIgnoreCase)) {
            $r.UnderProgramFiles = $true
            break
        }
    }

    if ($r.UnderProgramFiles) {
        $drive = [System.IO.Path]::GetPathRoot($GameFolder).TrimEnd('\')
        $rel = $GameFolder.Substring($drive.Length).TrimStart('\')
        $cand = Join-Path $env:LOCALAPPDATA ('VirtualStore\' + $rel)
        $r.VirtualStorePath = $cand
        $r.VirtualStoreHit = (Test-Path -LiteralPath $cand)
    }

    return $r
}

function Get-TrdMemoryState {
    [CmdletBinding()]
    param()
    $r = [PSCustomObject]@{ TotalMB = 0; FreeMB = 0 }
    $os = Get-TrdWmiObject -ClassName 'Win32_OperatingSystem'
    if ($os) {
        try {
            $r.TotalMB = [Math]::Round([double]$os.TotalVisibleMemorySize / 1KB, 0)
            $r.FreeMB  = [Math]::Round([double]$os.FreePhysicalMemory / 1KB, 0)
        } catch { }
    }
    return $r
}
