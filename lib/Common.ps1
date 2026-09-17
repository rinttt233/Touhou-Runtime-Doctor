# ============================================================================
#  Common.ps1 -- 公共基础层
#  提供：日志、提权检测、备份/回滚日志、离线载荷目录解析、注册表安全写入、
#        路径与编码工具。
#  约定：本文件所有中文均以 UTF-8 BOM 保存，勿用无 BOM 方式重写。
# ============================================================================
Set-StrictMode -Version 2.0

# ---------------------------------------------------------------------------
#  全局状态（由主引擎初始化）
# ---------------------------------------------------------------------------
$script:TRD = [PSCustomObject]@{
    ToolVersion   = '1.0.1'    # 由 VERSION.txt 覆盖
    ToolRoot      = $null      # 工具根目录
    OfflineRoot   = $null      # 离线载荷目录
    BackupRoot    = $null      # 备份根目录
    SessionDir    = $null      # 本次运行的备份目录
    Journal       = $null      # 备份日志(ArrayList)
    LogLines      = $null      # 供报告使用的日志
    LogFile       = $null
    IsAdmin       = $false
    DryRun        = $false
    ConsoleUtf8   = $false

    # --- 操作系统与运行时事实（位数处理全靠这几个字段，禁止在别处硬编码目录名）---
    Is64OS        = $false     # 宿主 Windows 是否为 64 位
    IsWow64       = $false     # 当前进程是否为"64 位系统上的 32 位进程"（会触发文件/注册表重定向）
    ProcessBitness = 'x86'     # 当前 PowerShell 进程自身的位数
    OSBuild       = 0
    OSCaption     = ''
    SystemDirNative = $null    # 本机"原生位数"的系统目录（64 位系统=System32，32 位系统=System32）
    SystemDirX86  = $null      # 放 32 位系统 DLL 的目录（64 位系统=SysWOW64，32 位系统=System32）
    SystemDirX64  = $null      # 放 64 位系统 DLL 的目录（32 位系统=$null，不存在）
    SystemDirX64Display = $null # SystemDirX64 的"给人看"形式（重定向规避时用 Sysnative 访问，但显示仍写 System32）
    HasWow64      = $false     # 是否存在 32 位子系统
    # 注册表视图：决定 SOFTWARE 分支读/写的是 64 位还是 32 位视图。
    # 不能用"进程默认视图"代替——32 位进程的默认视图是 32 位视图，
    # 会让 64 位 VC++ 运行库的安装记录整个看不见。
    RegViewNative = 'Registry64'  # 本机原生视图（32 位系统上为 Registry32）
    RegViewX86    = 'Registry32'
    PSMajor       = 0
    PSMinor       = 0
    PSEdition     = ''
    WmfUpToDate   = $false
}

function Get-TrdSystemDir {
    <#
    .SYNOPSIS
        返回指定位数对应的"系统目录"。
    .DESCRIPTION
        这是全工具唯一允许决定"去哪个目录找系统 DLL"的地方，别处一律调用它。
        硬编码 SysWOW64 在 32 位 Windows 上是错的：
          64 位系统：x86 -> SysWOW64，x64 -> System32
          32 位系统：x86 -> System32（根本没有 WOW64 层），x64 -> 不适用
        这个错误不会报异常，只会让所有组件检查集体"报缺失"，
        把一台健康的 32 位机器判成需要大修。

        第二条坑更隐蔽：32 位进程（WOW64）访问 C:\Windows\System32 会被
        文件系统重定向【静默改写】成 C:\Windows\SysWOW64。于是"检查 x64 组件"
        实际查的是 x86 文件 —— 大小、版本、哈希全是错的，而且会因为同名 x86
        文件存在而假报"已安装"。所以 WOW64 场景下 x64 目标必须用 Sysnative。
        （Sysnative 只是 32 位进程可见的别名，64 位进程下不存在，故按需选用。）
    .OUTPUTS
        目录路径；该位数在本机不适用时返回 $null。
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][ValidateSet('x86', 'x64')][string]$Bitness)

    # 未初始化时按当前进程环境兜底（便于单独加载本文件做测试）
    $is64 = $script:TRD.Is64OS
    $isWow = $script:TRD.IsWow64
    if ($null -eq $script:TRD.SystemDirX86) {
        $procArch = [string]$env:PROCESSOR_ARCHITECTURE
        $isNative64 = ($procArch -eq 'AMD64' -or $procArch -eq 'IA64' -or $procArch -eq 'ARM64')
        $is64 = ($isNative64 -or [bool]$env:PROCESSOR_ARCHITEW6432)
        $isWow = ($is64 -and -not $isNative64)
    }

    $root = $env:SystemRoot
    if (-not $root) { return $null }

    if ($Bitness -eq 'x86') {
        # SysWOW64 本身就是 32 位目录，不受重定向影响，32 位进程也能正确读到
        if ($is64) { return (Join-Path $root 'SysWOW64') }
        return (Join-Path $root 'System32')
    }

    # x64
    if (-not $is64) { return $null }          # 32 位系统上不存在 64 位系统目录
    if ($isWow) { return (Join-Path $root 'Sysnative') }
    return (Join-Path $root 'System32')
}

function Get-TrdSystemToolPath {
    <#
    .SYNOPSIS
        返回系统自带工具（reg.exe 等）的【原生位数】完整路径。
    .DESCRIPTION
        为什么不能直接用 "$env:windir\System32\reg.exe"：
        32 位进程访问 System32 会被重定向到 SysWOW64，拿到的是 32 位 reg.exe，
        而 32 位 reg.exe 读写的注册表视图也是 32 位视图。后果很隐蔽：
        给【原生视图】的分支做回滚快照时会导出错误的内容，
        回滚时再把错误内容导回去 —— 用户以为还原了，其实没有。
        这里优先走 Sysnative，保证拿到的工具与宿主系统同位。
    .OUTPUTS
        工具完整路径；都找不到时返回裸名字，交给 PATH 解析。
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Name)

    $cands = New-Object System.Collections.ArrayList
    if ($script:TRD.IsWow64) { $null = $cands.Add((Join-Path $env:SystemRoot ('Sysnative\' + $Name))) }
    $null = $cands.Add((Join-Path $env:SystemRoot ('System32\' + $Name)))
    if ($script:TRD.Is64OS) { $null = $cands.Add((Join-Path $env:SystemRoot ('SysWOW64\' + $Name))) }
    foreach ($c in $cands) {
        if (Test-Path -LiteralPath $c) { return $c }
    }
    return $Name
}

function ConvertTo-TrdDisplayPath {
    <#
    .SYNOPSIS
        把只用于访问的别名路径还原成用户能认出来的真实路径。
    .DESCRIPTION
        在 64 位系统上跑 32 位 PowerShell 时，为了绕开 WOW64 文件系统重定向，
        访问 x64 系统目录必须写成 C:\Windows\Sysnative。
        但 Sysnative 是"进程私有别名"，用户在资源管理器里根本看不到它，
        报告里直接写出来只会让人以为文件不在。
        所以显示前统一还原成 C:\Windows\System32（两者指向同一个目录）。

        必须用 \b 而不是要求后面跟反斜杠：路径常出现在句末或中文括号前，
        例如 "64 位组件目录: C:\WINDOWS\Sysnative（东方系列为 32 位程序）"。
        早期版本写成 '\\Sysnative\\'，这类没有尾随斜杠的情况全都漏掉了，
        报告里于是残留了 2 处 Sysnative。
    #>
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    if ($Text.IndexOf('Sysnative', [System.StringComparison]::OrdinalIgnoreCase) -lt 0) { return $Text }
    return ($Text -replace '(?i)\\Sysnative\b', '\System32')
}

function Get-TrdOfflineHint {
    <#
    .SYNOPSIS
        返回"如何补齐离线载荷"的提示语，按发行版形态自适应。
    .DESCRIPTION
        公开发行版（lite）刻意不含 tools\Fetch-OfflinePack.ps1，
        也不含任何自动联网下载能力。此时若仍旧提示用户
        "去运行 Fetch-OfflinePack.ps1"，就是一条走不通的空指向，
        用户会以为文件丢了或被杀软删了。
        所以这里按住处的发行版里那个脚本是否真的存在来选择文案。
    .PARAMETER Short
        返回适合塞进单行日志的短句。
    #>
    [CmdletBinding()]
    param([switch]$Short)

    $fetcher = $null
    if ($script:TRD.ToolRoot) { $fetcher = Join-Path $script:TRD.ToolRoot 'tools\Fetch-OfflinePack.ps1' }

    if ($fetcher -and (Test-Path -LiteralPath $fetcher)) {
        if ($Short) { return '请运行 tools\Fetch-OfflinePack.ps1 补齐离线载荷后重跑。' }
        return '请在一台能联网的机器上运行 tools\Fetch-OfflinePack.ps1 把载荷灌进 offline\ 目录，或手工把安装包放到 offline\ 下。'
    }

    if ($Short) { return '请把对应的安装包手工放入 offline\ 目录后重跑。' }
    return '本发行版不含自动下载功能：请手工获取对应的 VC++ 运行库 / DirectX 安装包，放进 offline\ 目录后重跑。'
}

function Get-TrdFileHashSafe {
    <#
    .SYNOPSIS
        计算文件 SHA256，兼容 PowerShell 3.0/4.0（它们没有 Get-FileHash）。
    .DESCRIPTION
        Get-FileHash 是 PowerShell 4.0 才有的。为了能在只装了 WMF 3.0 的
        老机器上跑，这里直接用 .NET 的 SHA256 实现。
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    try {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $fs = [System.IO.File]::OpenRead($Path)
        try {
            $bytes = $sha.ComputeHash($fs)
        } finally {
            $fs.Close(); $fs.Dispose(); $sha.Dispose()
        }
        $sb = New-Object System.Text.StringBuilder
        foreach ($b in $bytes) { $null = $sb.Append($b.ToString('X2')) }
        return $sb.ToString()
    } catch {
        return $null
    }
}

function Expand-TrdArchive {
    <#
    .SYNOPSIS
        解压 zip，兼容 PowerShell 3.0/4.0（它们没有 Expand-Archive）。
    .DESCRIPTION
        优先用系统自带的 Expand-Archive（PS5+）；否则退回 .NET 的
        System.IO.Compression.ZipFile（需要 .NET 4.5+，Win7 SP1 通常已具备）；
        再不行用 Shell.Application COM（最老但几乎总是可用）。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ZipPath,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    if (-not (Test-Path -LiteralPath $Destination)) {
        $null = New-Item -ItemType Directory -Path $Destination -Force
    }

    # 1) PS5+ 内置
    $ea = Get-Command -Name 'Expand-Archive' -ErrorAction SilentlyContinue
    if ($ea) {
        Expand-Archive -LiteralPath $ZipPath -DestinationPath $Destination -Force -ErrorAction Stop
        return $true
    }

    # 2) .NET 4.5+
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
        [System.IO.Compression.ZipFile]::ExtractToDirectory($ZipPath, $Destination)
        return $true
    } catch { }

    # 3) Shell.Application COM（最后兜底）
    try {
        $shell = New-Object -ComObject Shell.Application
        $zipNs = $shell.NameSpace($ZipPath)
        $dstNs = $shell.NameSpace($Destination)
        if ($zipNs -and $dstNs) {
            $dstNs.CopyHere($zipNs.Items(), 0x14)   # 0x14 = 不弹 UI + 覆盖
            return $true
        }
    } catch { }

    throw "无法解压 $ZipPath（本机缺少 Expand-Archive，且 .NET/COM 兜底均失败）"
}

function Get-TrdChildDirectory {
    <#
    .SYNOPSIS
        按指定深度枚举子目录，兼容 PowerShell 3.0/4.0（它们没有 -Depth 参数）。
    .DESCRIPTION
        Get-ChildItem -Depth 是 PowerShell 5.0 才有的。老机器上会直接报
        "找不到与参数名称 Depth 匹配的参数"。这里用显式队列做广度遍历，
        并且拒绝进入重解析点（符号链接/junction），避免在 Windows 上
        因为目录联接而无限递归或跨盘乱跑。

        深度语义与 Get-ChildItem -Recurse -Depth N 对齐：N 表示"向下递归的层数"，
        N=3 时能枚举到第 4 层目录（根 -> L1 -> L2 -> L3 -> L4）。
        写成 $cur.Depth -ge $MaxDepth 会少查一层，曾经因此漏掉了放在
        E:\download\...\正作\th07 这种较深路径下的游戏。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$MaxDepth = 3
    )

    $out = New-Object System.Collections.ArrayList
    if (-not (Test-Path -LiteralPath $Path)) { return @() }

    $queue = New-Object System.Collections.Queue
    $queue.Enqueue([PSCustomObject]@{ Dir = $Path; Depth = 0 })

    while ($queue.Count -gt 0) {
        $cur = $queue.Dequeue()
        if ($cur.Depth -gt $MaxDepth) { continue }

        $children = @()
        try {
            $children = @(Get-ChildItem -LiteralPath $cur.Dir -Directory -Force -ErrorAction SilentlyContinue)
        } catch { continue }

        foreach ($c in $children) {
            # 跳过重解析点：Windows 上的 junction/符号链接会让遍历成环或跑到别的盘
            if ($c.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
            $null = $out.Add($c)
            $queue.Enqueue([PSCustomObject]@{ Dir = $c.FullName; Depth = ($cur.Depth + 1) })
        }
    }
    return @($out)
}

function Get-TrdWmiObject {
    <#
    .SYNOPSIS
        查询 WMI/CIM，兼容 PowerShell 2.0~5.1。
    .DESCRIPTION
        Get-CimInstance 是 PowerShell 3.0 才有的；老机器上退回 Get-WmiObject。
        两者返回的对象属性名基本一致，调用方按属性名访问即可。
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ClassName)

    $cim = Get-Command -Name 'Get-CimInstance' -ErrorAction SilentlyContinue
    if ($cim) {
        try { return Get-CimInstance -ClassName $ClassName -ErrorAction Stop } catch { }
    }
    try { return Get-WmiObject -Class $ClassName -ErrorAction Stop } catch { }
    return $null
}

function Invoke-TrdSelfTest {
    <#
    .SYNOPSIS
        在当前机器上实测工具的每一项能力，回答"这台机器能不能用"。
    .DESCRIPTION
        工具的目标环境横跨 Windows 7~11、32~64 位、PowerShell 3.0~5.1。
        很多能力的可用性在不同环境下并不一致（.NET 注册表 API、zip 解压后端、
        WMI 查询、PE 解析都要靠具体实现）。与其让用户在不同机器上撞到不同的墙，
        不如一次把能力全部实测一遍，直接告诉他哪些可用、哪些不可用。
    .OUTPUTS
        检查项数组：Name, Ok, Critical, Detail
    #>
    [CmdletBinding()]
    param()

    $out = New-Object System.Collections.ArrayList
    $add = {
        param([string]$Name, [bool]$Ok, [string]$Detail, [bool]$Critical = $true)
        $null = $out.Add([PSCustomObject]@{ Name = $Name; Ok = $Ok; Detail = $Detail; Critical = $Critical })
    }

    # ---- 1. PowerShell 版本 ----
    $pv = $PSVersionTable.PSVersion
    & $add 'PowerShell 版本' ([int]$pv.Major -ge 3) "当前 $pv（需要 3.0 以上，建议 5.1）" $true

    # ---- 2. 系统位数判定 ----
    $arch = [string]$env:PROCESSOR_ARCHITECTURE
    $wow  = [string]$env:PROCESSOR_ARCHITEW6432
    $archDetail = "PROCESSOR_ARCHITECTURE=$arch" +
        $(if ($wow) { "，PROCESSOR_ARCHITEW6432=$wow（当前是 WOW64 下的 32 位进程，宿主为 64 位系统）" } else { '' }) +
        "；判定结果：$(if ($script:TRD.Is64OS) { '64 位系统' } else { '32 位系统' })"
    & $add '系统位数判定' ($arch -ne '') $archDetail $true

    # ---- 3. 系统目录映射（32 位系统上最容易出错的地方）----
    $d86 = Get-TrdSystemDir -Bitness 'x86'
    $d64 = Get-TrdSystemDir -Bitness 'x64'
    $mapOk = $true; $mapDetail = ''
    if (-not $d86 -or -not (Test-Path -LiteralPath $d86)) {
        $mapOk = $false; $mapDetail = "32 位系统目录不可用: $d86"
    } elseif ($script:TRD.Is64OS) {
        if ($d86 -notmatch 'SysWOW64$') { $mapOk = $false; $mapDetail = "64 位系统上 32 位目录应为 SysWOW64，实际得到 $d86" }
        elseif (-not $d64 -or -not (Test-Path -LiteralPath $d64)) { $mapOk = $false; $mapDetail = "64 位系统目录不可用: $d64" }
        else { $mapDetail = "32 位 -> $d86 ；64 位 -> $d64" }
    } else {
        if ($d86 -notmatch 'System32$') { $mapOk = $false; $mapDetail = "32 位系统上 32 位目录应为 System32，实际得到 $d86" }
        elseif ($d64) { $mapOk = $false; $mapDetail = "32 位系统不应存在 64 位目录，实际得到 $d64" }
        else { $mapDetail = "32 位 -> $d86 ；64 位 -> 不适用（符合 32 位系统预期）" }
    }
    & $add '系统目录位数映射' $mapOk $mapDetail $true

    # ---- 3b. WOW64 重定向是否被真正规避 ----
    # 这是最难自查、后果最严重的一类环境问题：
    # 在 64 位系统上以 32 位 PowerShell 运行时，Windows 会把
    #   C:\Windows\System32                 静默改写到 SysWOW64
    #   HKLM\SOFTWARE\...                   静默改写到 SOFTWARE\WOW6432Node
    # 两者都不报错。于是工具"以为"自己在查 64 位组件，实际查的是 32 位文件；
    # "以为"在读全部卸载记录，实际只读到 x86 那一半 —— 最后输出一份
    # 看起来很正常、但结论完全错误的报告，还可能触发多余的重装。
    # 所以这里不靠"目录名对不对"判断，而是实测文件真实位数与两个注册表视图。
    $rdOk = $true; $rdDetail = ''
    if ($script:TRD.IsWow64) {
        $rdParts = New-Object System.Collections.ArrayList
        $k32 = Join-Path $d64 'kernel32.dll'
        $peInfo = $null
        try { $peInfo = Get-PeInfo -Path $k32 } catch { }
        if (-not $peInfo -or -not $peInfo.Ok) {
            $rdOk = $false; $null = $rdParts.Add("无法解析 $k32")
        } elseif ($peInfo.Arch -ne 'x64') {
            $rdOk = $false
            $null = $rdParts.Add("文件系统重定向未被规避：$k32 实际是 $($peInfo.Arch) 文件，应为 x64")
        } else {
            $null = $rdParts.Add("文件系统：经 Sysnative 读到真正的 x64 目录（kernel32.dll = $($peInfo.Arch)）")
        }

        # 注册表：两个视图必须各自独立打开成功，且不能互相串台
        try {
            $kV64 = Open-TrdRegSubKey -RegPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion' -View Native
            $kV32 = Open-TrdRegSubKey -RegPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion' -View X86
            if ($kV64) { $kV64.Close() }
            if ($kV32) { $kV32.Close() }
            $null = $rdParts.Add('注册表：64 位视图与 32 位视图均可独立打开')
        } catch {
            $rdOk = $false
            $null = $rdParts.Add("注册表视图打开失败: $($_.Exception.Message)")
        }

        $rdDetail = '当前进程 ' + $script:TRD.ProcessBitness + '，宿主 64 位（WOW64）。' + ($rdParts -join '；')
    } else {
        $rdDetail = "当前进程位数与宿主一致（$($script:TRD.ProcessBitness)），不存在 WOW64 重定向"
    }
    & $add 'WOW64 重定向规避' $rdOk $rdDetail $true

    # ---- 4. .NET 注册表 API（值名含方括号时唯一可靠的方式）----
    $regOk = $false; $regDetail = ''
    $tmpKey = 'HKCU:\SOFTWARE\TouhouRuntimeDoctor\SelfTest'
    $probeName = 'D:\self test\[x86] probe.exe'
    try {
        $null = Set-TrdRegValueEx -RegPath $tmpKey -Name $probeName -Value '~ TEST DISABLEDWM' -Kind String
        $got = Get-TrdRegValueEx -RegPath $tmpKey -Name $probeName
        if ($got.Exists -and $got.Value -eq '~ TEST DISABLEDWM') {
            $regOk = $true
            $regDetail = "可读写含方括号的值名（探针值名: $probeName）"
        } else {
            $regDetail = "读回结果不符: Exists=$($got.Exists) Value=$($got.Value)"
        }
        $null = Remove-TrdRegValueEx -RegPath $tmpKey -Name $probeName
    } catch {
        $regDetail = "异常: $($_.Exception.Message)"
    }
    # 清理自检用的临时分支
    try { Remove-Item -LiteralPath 'HKCU:\SOFTWARE\TouhouRuntimeDoctor' -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    & $add '.NET 注册表读写' $regOk $regDetail $true

    # ---- 5. 命令行参数引号处理 ----
    $argLine = ConvertTo-TrdArgString @('export', 'HKCU\SOFTWARE\Microsoft\Windows NT\CurrentVersion', 'D:\a b\c.reg', '/y')
    $argOk = ($argLine -match '"HKCU\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion"') -and
             ($argLine -match '"D:\\a b\\c\.reg"')
    & $add '命令行参数引号' $argOk $argLine $true

    # ---- 6. 文件哈希（Get-FileHash 的降级实现）----
    $hashOk = $false; $hashDetail = ''
    try {
        $probe = Join-Path $script:TRD.SessionDir 'selftest_hash.txt'
        [System.IO.File]::WriteAllText($probe, 'abc', (New-Object System.Text.UTF8Encoding($false)))
        $h = Get-TrdFileHashSafe -Path $probe
        # "abc" 的 SHA256 是固定公开值，可以直接验算，不需要外部参考
        $expected = 'BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD'
        $hashOk = ($h -eq $expected)
        $hashDetail = "SHA256('abc') = $h"
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
    } catch { $hashDetail = "异常: $($_.Exception.Message)" }
    & $add 'SHA256 计算' $hashOk $hashDetail $true

    # ---- 7. zip 解压后端 ----
    $zipBackend = '无'
    if (Get-Command -Name 'Expand-Archive' -ErrorAction SilentlyContinue) {
        $zipBackend = 'Expand-Archive（PowerShell 5.0+ 内置）'
    } else {
        try {
            Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
            $zipBackend = 'System.IO.Compression（.NET 4.5+）'
        } catch {
            try { $null = New-Object -ComObject Shell.Application; $zipBackend = 'Shell.Application COM（兜底）' } catch { }
        }
    }
    & $add 'zip 解压能力' ($zipBackend -ne '无') $zipBackend $false

    # ---- 8. WMI / CIM 查询 ----
    $wmi = Get-TrdWmiObject -ClassName 'Win32_OperatingSystem'
    $wmiDetail = if ($wmi) { "已获取: $([string]$wmi.Caption)" } else { 'Get-CimInstance 与 Get-WmiObject 均不可用' }
    & $add 'WMI 系统信息查询' ([bool]$wmi) $wmiDetail $false

    # ---- 9. PE 解析能力（用当前 PowerShell 主程序当样本）----
    $peOk = $false; $peDetail = ''
    try {
        # 样本取【原生位数】目录里的 powershell.exe：若直接写 System32，
        # 32 位进程下会被重定向到 SysWOW64，解析出来的位数是 x86，
        # 这条自检就会在 64 位机器上给出一个让人困惑的结论。
        $peDir = Get-TrdSystemDir -Bitness 'x64'
        if (-not $peDir) { $peDir = Get-TrdSystemDir -Bitness 'x86' }
        $psExe = Join-Path $peDir 'WindowsPowerShell\v1.0\powershell.exe'
        if (Test-Path -LiteralPath $psExe) {
            $info = Get-PeInfo -Path $psExe
            $peOk = ($info.Ok -and $info.Imports.Count -gt 0)
            $peDetail = "样本 $(Split-Path -Leaf $psExe) -> 位数 $($info.Arch)，解析到 $($info.Imports.Count) 项导入"
        } else { $peDetail = '找不到样本 powershell.exe' }
    } catch { $peDetail = "异常: $($_.Exception.Message)" }
    & $add 'PE 导入表解析' $peOk $peDetail $true

    # ---- 10. 目录深度遍历（-Depth 的降级实现）----
    $dirs = @(Get-TrdChildDirectory -Path $script:TRD.ToolRoot -MaxDepth 2)
    & $add '目录深度遍历' ($dirs.Count -gt 0) "在工具目录下枚举到 $($dirs.Count) 个子目录（未使用 PS5 专有的 -Depth）" $false

    # ---- 11. 离线载荷清单解析 ----
    $mf = Get-TrdOfflineManifest
    $pkgCount = 0
    if ($mf -and $mf.PSObject.Properties.Name -contains 'Packages') { $pkgCount = @($mf.Packages).Count }
    & $add '离线载荷清单' ($pkgCount -gt 0) "解析到 $pkgCount 个载荷条目" $false

    # ---- 12. 备份与还原往返 ----
    $bkOk = $false; $bkDetail = ''
    try {
        $src = Join-Path $script:TRD.SessionDir 'selftest_backup.txt'
        [System.IO.File]::WriteAllText($src, 'roundtrip', (New-Object System.Text.UTF8Encoding($false)))
        $bk = Backup-TrdFile -Path $src -Tag 'selftest'
        if ($bk -and (Test-Path -LiteralPath $bk)) {
            [System.IO.File]::WriteAllText($src, 'MODIFIED', (New-Object System.Text.UTF8Encoding($false)))
            Copy-Item -LiteralPath $bk -Destination $src -Force
            $back = [System.IO.File]::ReadAllText($src, [System.Text.Encoding]::UTF8)
            $bkOk = ($back -eq 'roundtrip')
            $bkDetail = "备份 -> 改写 -> 还原 往返$(if ($bkOk) { '内容一致' } else { '内容不一致' })"
            Remove-Item -LiteralPath $src -Force -ErrorAction SilentlyContinue
        } else { $bkDetail = '备份文件未生成' }
    } catch { $bkDetail = "异常: $($_.Exception.Message)" }
    & $add '文件备份/还原' $bkOk $bkDetail $true

    return @($out)
}

function Test-TrdRuntimePrerequisites {
    <#
    .SYNOPSIS
        启动前检查 PowerShell 版本与操作系统位数，返回问题清单。
    .DESCRIPTION
        Windows 7 出厂只带 PowerShell 2.0。本工具用到 ConvertFrom-Json、
        -File/-Directory、-Stream 等 PowerShell 3.0 才有的能力，
        没有这一层检查的话，用户看到的会是一堆莫名其妙的语法/参数错误。
    #>
    [CmdletBinding()]
    param()

    $issues = New-Object System.Collections.ArrayList

    $v = $PSVersionTable.PSVersion
    $major = [int]$v.Major
    $minor = [int]$v.Minor

    if ($major -lt 3) {
        $null = $issues.Add([PSCustomObject]@{
            Level = 'Fatal'
            Title = "PowerShell 版本过低（当前 $major.$minor，需要 3.0 以上）"
            Detail = 'Windows 7 出厂只自带 PowerShell 2.0。请安装 Windows Management Framework 5.1' +
                     '（Win7 需先装 SP1 与 .NET Framework 4.5.2 以上），装完重启再运行本工具。'
        })
    } elseif ($major -lt 5) {
        $null = $issues.Add([PSCustomObject]@{
            Level = 'Warn'
            Title = "PowerShell 版本偏旧（当前 $major.$minor，建议 5.1）"
            Detail = '工具已内置降级实现（哈希、解压、目录深度遍历都有兜底），可以继续使用；' +
                     '但安装 WMF 5.1 后体验更稳。'
        })
    }

    return @($issues)
}

function Initialize-TrdEnvironment {
    <#
    .SYNOPSIS
        初始化工具运行环境：目录、备份会话、日志缓冲。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ToolRoot,
        [string]$OfflineRoot,
        [string]$BackupRoot,
        [switch]$DryRun
    )

    $script:TRD.ToolRoot = (Resolve-Path -LiteralPath $ToolRoot).Path
    if (-not $OfflineRoot) { $OfflineRoot = Join-Path $script:TRD.ToolRoot 'offline' }
    if (-not $BackupRoot)  { $BackupRoot  = Join-Path $script:TRD.ToolRoot 'backup' }
    $script:TRD.OfflineRoot = $OfflineRoot
    $script:TRD.BackupRoot  = $BackupRoot
    $script:TRD.DryRun      = [bool]$DryRun

    # 版本号从 VERSION.txt 读，方便打包时不改代码就能标版本
    try {
        $vf = Join-Path $script:TRD.ToolRoot 'VERSION.txt'
        if (Test-Path -LiteralPath $vf) {
            $v = ([System.IO.File]::ReadAllText($vf, [System.Text.Encoding]::UTF8)).Trim()
            if ($v) { $script:TRD.ToolVersion = $v }
        }
    } catch { }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $script:TRD.SessionDir = Join-Path $BackupRoot $stamp
    $script:TRD.Journal    = New-Object System.Collections.ArrayList
    $script:TRD.LogLines   = New-Object System.Collections.ArrayList

    $script:TRD.IsAdmin = Test-TrdAdmin

    # --- 操作系统位数：全局只在这里判定一次 ---
    # 注意不能用 $env:PROCESSOR_ARCHITECTURE 单独判断：在 64 位系统上以 32 位
    # PowerShell 运行时它是 "x86"，会把 64 位系统误判成 32 位。
    # PROCESSOR_ARCHITEW6432 存在，就说明当前是 WOW64 下的 32 位进程，
    # 宿主系统其实是 64 位。
    $arch = [string]$env:PROCESSOR_ARCHITECTURE
    $archWow = [string]$env:PROCESSOR_ARCHITEW6432
    $script:TRD.Is64OS = ($arch -eq 'AMD64' -or $arch -eq 'IA64' -or
                          $arch -eq 'ARM64' -or [bool]$archWow)

    # 当前进程自身位数，以及最要命的一种组合：64 位系统上跑 32 位进程（WOW64）。
    # 这种组合下 System32 会被重定向成 SysWOW64、SOFTWARE 会被重定向成
    # WOW6432Node，所有"看系统真实状态"的检查都会读错，必须先识别出来。
    $procIs64 = ($arch -eq 'AMD64' -or $arch -eq 'IA64' -or $arch -eq 'ARM64')
    $script:TRD.ProcessBitness = if ($procIs64) { 'x64' } else { 'x86' }
    $script:TRD.IsWow64 = ($script:TRD.Is64OS -and -not $procIs64)

    # 注册表视图：原生视图固定按宿主系统位数选，绝不跟随进程默认视图
    if ($script:TRD.Is64OS) {
        $script:TRD.RegViewNative = 'Registry64'
    } else {
        $script:TRD.RegViewNative = 'Registry32'
    }
    $script:TRD.RegViewX86 = 'Registry32'

    $script:TRD.SystemDirX86 = Get-TrdSystemDir -Bitness 'x86'
    $script:TRD.SystemDirX64 = Get-TrdSystemDir -Bitness 'x64'
    # 给人看的路径：Sysnative 只是访问用的别名，写进报告会让人困惑
    $script:TRD.SystemDirX64Display = if ($script:TRD.SystemDirX64) {
        Join-Path $env:SystemRoot 'System32'
    } else {
        $null
    }
    $script:TRD.SystemDirNative = Join-Path $env:SystemRoot 'System32'
    $script:TRD.HasWow64 = if ($script:TRD.Is64OS) {
        Test-Path -LiteralPath (Join-Path $env:SystemRoot 'SysWOW64')
    } else {
        $false   # 32 位系统不需要也不存在 WOW64 层
    }

    $script:TRD.PSMajor   = [int]$PSVersionTable.PSVersion.Major
    $script:TRD.PSMinor   = [int]$PSVersionTable.PSVersion.Minor
    $script:TRD.PSEdition = [string]$PSVersionTable.PSEdition
    if (-not $script:TRD.PSEdition) { $script:TRD.PSEdition = 'Desktop' }
    $script:TRD.WmfUpToDate = ($script:TRD.PSMajor -ge 5)

    foreach ($d in @($script:TRD.OfflineRoot, $script:TRD.BackupRoot, $script:TRD.SessionDir)) {
        if (-not (Test-Path -LiteralPath $d)) {
            try { $null = New-Item -ItemType Directory -Path $d -Force -ErrorAction Stop } catch { }
        }
    }
    $script:TRD.LogFile = Join-Path $script:TRD.SessionDir 'run.log'
}

function Test-TrdAdmin {
    try {
        $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $pr = New-Object System.Security.Principal.WindowsPrincipal($id)
        return $pr.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

# ---------------------------------------------------------------------------
#  日志
# ---------------------------------------------------------------------------
function Write-TrdLog {
    <#
    .SYNOPSIS
        统一日志出口：控制台着色 + 内存缓冲 + 落盘。
    .PARAMETER Level
        Title / Step / OK / Warn / Error / Info / Detail
    #>
    [CmdletBinding()]
    param(
        # AllowEmptyString 是必需的：调用方经常用 Write-TrdLog '' 输出空行，
        # 而 Mandatory 默认会拒绝空字符串，导致整个工具在打印第一个空行时就崩掉。
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Message,
        [ValidateSet('Title', 'Step', 'OK', 'Warn', 'Error', 'Info', 'Detail')]
        [string]$Level = 'Info',
        [switch]$NoNewline
    )

    $prefix = switch ($Level) {
        'Title'  { '' }
        'Step'   { '[ .. ] ' }
        'OK'     { '[ OK ] ' }
        'Warn'   { '[警告] ' }
        'Error'  { '[失败] ' }
        'Info'   { '[信息] ' }
        'Detail' { '       ' }
    }

    $color = switch ($Level) {
        'Title'  { 'Cyan' }
        'Step'   { 'White' }
        'OK'     { 'Green' }
        'Warn'   { 'Yellow' }
        'Error'  { 'Red' }
        'Info'   { 'Gray' }
        'Detail' { 'DarkGray' }
    }

    $line = "$prefix$Message"
    Write-Host $line -ForegroundColor $color -NoNewline:$NoNewline
    if (-not $NoNewline) { $null = $script:TRD.LogLines.Add($line) }

    if ($script:TRD.LogFile -and -not $NoNewline) {
        try {
            Add-Content -LiteralPath $script:TRD.LogFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
        } catch { }
    }
}

function Write-TrdBanner {
    param([string]$SubTitle)
    Write-TrdLog ('=' * 74) 'Title'
    Write-TrdLog '  Touhou Runtime Doctor  --  东方 Project 运行环境一键体检修复工具' 'Title'
    if ($SubTitle) { Write-TrdLog "  $SubTitle" 'Title' }
    Write-TrdLog ('=' * 74) 'Title'
}

# ---------------------------------------------------------------------------
#  备份 / 回滚
# ---------------------------------------------------------------------------
function Backup-TrdFile {
    <#
    .SYNOPSIS
        把文件复制进本次会话的备份目录，并写入回滚日志。
    .OUTPUTS
        备份后的路径；文件不存在则返回 $null（不视为错误）。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$Tag = 'file'
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }

    $destDir = Join-Path $script:TRD.SessionDir "files\$Tag"
    if (-not (Test-Path -LiteralPath $destDir)) { $null = New-Item -ItemType Directory -Path $destDir -Force }

    $name = Split-Path -Leaf $Path
    $dest = Join-Path $destDir $name
    $n = 1
    while (Test-Path -LiteralPath $dest) {
        $dest = Join-Path $destDir ("{0}.{1}" -f $name, $n); $n++
    }

    try {
        Copy-Item -LiteralPath $Path -Destination $dest -Force -ErrorAction Stop
        $null = $script:TRD.Journal.Add([PSCustomObject]@{
            Kind = 'File'; Target = $Path; Backup = $dest; Existed = $true
        })
        return $dest
    } catch {
        Write-TrdLog "备份失败: $Path -> $($_.Exception.Message)" 'Warn'
        return $null
    }
}

function ConvertTo-TrdArgString {
    <#
    .SYNOPSIS
        把参数数组拼成一条可安全传给 Start-Process / 原生程序的命令行。
    .DESCRIPTION
        为什么必须自己拼：
          Start-Process -ArgumentList 传数组时，PowerShell 只是用空格把元素【直接拼接】，
          不会给含空格的元素加引号。于是像
              reg export HKCU\SOFTWARE\Microsoft\Windows NT\... D:\a b\x.reg /y
          这样的命令会在 "Windows NT" 处被截断，reg.exe 直接报 Invalid syntax。
          这个坑在路径含空格的机器上会让备份悄悄失效，必须显式加引号。
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Arguments)

    $parts = New-Object System.Collections.ArrayList
    foreach ($a in $Arguments) {
        if ($null -eq $a) { continue }
        if ($a.Length -eq 0) { $null = $parts.Add('""'); continue }
        # 含空格、制表符或引号才需要包裹
        if ($a -match '[\s"]') {
            $null = $parts.Add('"' + ($a -replace '"', '\"') + '"')
        } else {
            $null = $parts.Add($a)
        }
    }
    return ($parts -join ' ')
}

function ConvertTo-TrdRegPsPath {
    <#
    .SYNOPSIS
        把 reg.exe 形式的注册表路径转换成 PowerShell PSDrive 形式（带冒号）。
    .DESCRIPTION
        ConvertTo-TrdRegExePath 的反向操作。两个方向都需要：
          * 给 reg.exe 用    -> 必须是无冒号的 HKCU\...
          * 给 Test-Path 用  -> 必须是有冒号的 HKCU:\...
        混用会产生静默错误：把 HKCU\... 交给 Test-Path，它会被当成相对文件路径
        去找，恒为 False，于是"备份明明成功了却被标记成原本不存在"。
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$RegPath)

    $p = ConvertTo-TrdRegExePath -RegPath $RegPath
    if ($p -match '^([A-Za-z_]+)\\(.*)$') {
        return ($Matches[1] + ':\' + $Matches[2])
    }
    if ($p -match '^([A-Za-z_]+)$') { return ($Matches[1] + ':') }
    return $null
}

function ConvertTo-TrdRegExePath {
    <#
    .SYNOPSIS
        把 PowerShell 的 PSDrive 写法转换成 reg.exe 认识的写法。
    .DESCRIPTION
        两种写法在日常使用中很容易混：
          PowerShell 提供程序  : HKCU:\SOFTWARE\Microsoft\...   （有冒号）
          reg.exe / .reg 文件  : HKCU\SOFTWARE\Microsoft\...    （无冒号）
        把带冒号的形式直接喂给 reg.exe，会得到 "ERROR: Invalid key name."
        而且这个错误是静默的——导出失败后备份文件不存在，回滚时会缺项。
        这里统一归一化，并且用它做"是否已备份过"的比较键，避免同一分支重复导出。
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$RegPath)

    $p = $RegPath.Trim()
    $p = $p -replace '^Registry::', ''
    # HKCU: -> HKCU   HKLM: -> HKLM   其余缩写同理
    $p = $p -replace '^([A-Za-z_]+):\\?', '$1\'
    # 同时接受 Registry::HKEY_CURRENT_USER\... 的长写法
    $p = $p -replace '^HKEY_CURRENT_USER', 'HKCU'
    $p = $p -replace '^HKEY_LOCAL_MACHINE', 'HKLM'
    $p = $p -replace '^HKEY_CLASSES_ROOT', 'HKCR'
    $p = $p -replace '^HKEY_USERS', 'HKU'
    $p = $p -replace '^HKEY_CURRENT_CONFIG', 'HKCC'
    return $p
}

function Backup-TrdRegKey {
    <#
    .SYNOPSIS
        用 reg.exe export 导出注册表分支到备份目录（比手工遍历可靠）。
    .PARAMETER RegPath
        PowerShell PSDrive 形式（HKCU:\...）或 reg.exe 形式（HKCU\...）都可以。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RegPath,
        [string]$Tag = 'reg'
    )

    $destDir = Join-Path $script:TRD.SessionDir "reg\$Tag"
    if (-not (Test-Path -LiteralPath $destDir)) { $null = New-Item -ItemType Directory -Path $destDir -Force }

    $safe = ($RegPath -replace '[\\/:*?"<>|]', '_')
    $dest = Join-Path $destDir "$safe.reg"

    # 判断"这个分支原来存不存在"必须用 PSDrive 形式（带冒号）。
    # 如果调用方传的是 reg.exe 形式（HKCU\... 无冒号），Test-Path 会把它当成
    # 【相对文件路径】去找，结果恒为 False —— 于是备份虽然成功了，
    # 却被标记成"原本不存在"，回滚时会拒绝还原，用户以为改动可逆其实不可逆。
    $psPath = ConvertTo-TrdRegPsPath -RegPath $RegPath
    $regExePath = ConvertTo-TrdRegExePath -RegPath $RegPath

    $keyExisted = $false
    if ($psPath) { $keyExisted = (Test-Path -LiteralPath $psPath) }

    # 以 reg.exe 的退出码为最终依据：导出返回 0 就证明该分支确实存在且已被完整导出，
    # 这比 Test-Path 更直接。导出失败则视为"没有可用备份"，回滚时会跳过并说明原因。
    $exportOk = $false
    $exportErr = $null
    try {
        $code = Invoke-TrdProcess -FilePath (Get-TrdSystemToolPath -Name 'reg.exe') `
                -Arguments (ConvertTo-TrdArgString @('export', $regExePath, $dest, '/y'))
        $exportOk = ($code -eq 0)
        if (-not $exportOk) { $exportErr = "reg export 退出码 $code" }
    } catch {
        $exportErr = $_.Exception.Message
    }

    $haveFile = $false
    if (Test-Path -LiteralPath $dest) {
        try { $haveFile = ((Get-Item -LiteralPath $dest).Length -gt 0) } catch { $haveFile = $false }
    }

    $existed = ($exportOk -and $haveFile)

    if (-not $existed) {
        # 备份失败必须显式告警：这意味着接下来对该分支的写入【不可回滚】。
        # 静默失败会让用户以为随时能撤销，这是最危险的。
        $why = if ($exportErr) { $exportErr } elseif ($haveFile) { '导出产物为空' } elseif (-not $keyExisted) { '该注册表分支当前不存在' } else { '未知原因' }
        Write-TrdLog "无法为 [$regExePath] 生成回滚备份（$why）。对该分支的修改将不可回滚。" 'Warn'
    }

    # 记录时统一用 reg.exe 形式，作为"是否已备份过"的比较键
    $null = $script:TRD.Journal.Add([PSCustomObject]@{
        Kind = 'RegKey'; Target = $regExePath
        Backup = $(if ($haveFile) { $dest } else { $null }); Existed = $existed
    })

    return [PSCustomObject]@{ Dest = $dest; Ok = $existed; Reason = $exportErr }
}

function Invoke-TrdProcess {
    <#
    .SYNOPSIS
        运行一个外部程序并可靠地拿到退出码。
    .DESCRIPTION
        不用 Start-Process -PassThru 的原因：它在这个场景下会抛
            "Cannot process request because the process (NNNN) has exited."
        —— 进程退出得比我们读取 ExitCode 更快时，句柄已被释放，读属性直接报错，
        于是命令明明执行成功了，脚本却当成失败。
        直接用 System.Diagnostics.Process 启动，它自己持有进程句柄，
        WaitForExit() 之后读 ExitCode 是可靠的。
    .OUTPUTS
        退出码（Int32）。启动失败返回 -1。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string]$Arguments = '',
        [string]$WorkingDirectory = ''
    )

    if (-not (Test-Path -LiteralPath $FilePath)) {
        Write-TrdLog "找不到可执行文件: $FilePath" 'Warn'
        return -1
    }

    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $FilePath
        $psi.Arguments = $Arguments
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $false
        if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }

        $p = [System.Diagnostics.Process]::Start($psi)
        $p.WaitForExit()
        return [int]$p.ExitCode
    } catch {
        Write-TrdLog "执行失败 $([System.IO.Path]::GetFileName($FilePath)) : $($_.Exception.Message)" 'Warn'
        return -1
    }
}

function Save-TrdJournal {
    if ($script:TRD.Journal.Count -eq 0) { return }
    $path = Join-Path $script:TRD.SessionDir 'journal.json'
    try {
        $script:TRD.Journal | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $path -Encoding UTF8
    } catch {
        Write-TrdLog "写入回滚日志失败: $($_.Exception.Message)" 'Warn'
    }
}

function ConvertFrom-TrdJsonArray {
    <#
    .SYNOPSIS
        把一段 JSON 文本解析成【扁平】的对象数组。
    .DESCRIPTION
        Windows PowerShell 5.1 在这里有一个非常隐蔽的坑：

            @(Get-Content x.json -Raw | ConvertFrom-Json)

        当 JSON 顶层是数组时，ConvertFrom-Json 会把整个数组当作【单个对象】
        写进管道；而 @(管道) 只负责收集管道输出的对象，不会递归展开，
        于是得到的是"只有一个元素的数组，那个元素才是真正的数组"。
        之后 $e.Kind 之类的属性访问会拿到整个数组，所有判断与分支静默失效
        —— 回滚功能就因为这个坑而报 "LiteralPath 为 null"。

        正确做法：用 -InputObject 传入字符串（此时结果是直接返回的表达式，
        @() 会正常展开），再显式展开一层，确保调用方拿到的一定是扁平数组。
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Json)

    if ([string]::IsNullOrWhiteSpace($Json)) { return @() }

    $parsed = $null
    try { $parsed = ConvertFrom-Json -InputObject $Json } catch { return @() }
    if ($null -eq $parsed) { return @() }

    $out = New-Object System.Collections.ArrayList
    if ($parsed -is [System.Array]) {
        foreach ($x in $parsed) { $null = $out.Add($x) }
    } else {
        $null = $out.Add($parsed)
    }
    return @($out)
}

function Get-TrdScalarValue {
    <#
    .SYNOPSIS
        从一个可能被错误解析成数组的属性里取出单个标量值。
    .DESCRIPTION
        对早期版本写坏的回滚日志做兼容：那些日志里 Target / Backup 可能
        是数组（甚至含 null）。这里统一取第一个非空值，避免把数组喂给
        Test-Path -LiteralPath 之类只接受单值的参数而抛异常。
    #>
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Array]) {
        foreach ($v in $Value) { if ($null -ne $v) { return $v } }
        return $null
    }
    return $Value
}

function Get-TrdProp {
    <#
    .SYNOPSIS
        安全地读取对象的属性，属性不存在时返回 $null。
    .DESCRIPTION
        在 Set-StrictMode -Version 2.0 下，访问不存在的属性会直接抛
        PropertyNotFoundException，而不是返回 $null。回滚日志里的条目
        形状本来就不一样（RegKey 有 Backup/Existed，RegValue 没有），
        所以必须显式判断属性是否存在，否则一条日志就能让整个回滚中断。
    #>
    param($Object, [Parameter(Mandatory = $true)][string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object.PSObject.Properties.Name -contains $Name) { return $Object.$Name }
    return $null
}

function Get-TrdRollbackSessions {
    <#
    .SYNOPSIS
        列出可以回滚的备份会话（按时间倒序）。
    .DESCRIPTION
        只返回 journal 里【确实有改动记录】的会话。
        这一点很重要：工具每次运行都会建一个带时间戳的会话目录，
        但只读体检 / 演练模式不会产生任何改动，journal.json 根本不存在。
        如果"最近一次"就是这么一次空运行，用户点回滚会看到什么都没发生，
        却没有任何解释 —— 那比报错更让人困惑。
    #>
    [CmdletBinding()]
    param()

    if (-not (Test-Path -LiteralPath $script:TRD.BackupRoot)) { return @() }

    $out = New-Object System.Collections.ArrayList
    foreach ($d in @(Get-ChildItem -LiteralPath $script:TRD.BackupRoot -Directory | Sort-Object Name -Descending)) {
        $jf = Join-Path $d.FullName 'journal.json'
        if (-not (Test-Path -LiteralPath $jf)) { continue }
        $entries = @(ConvertFrom-TrdJsonArray -Json (Get-Content -LiteralPath $jf -Raw -Encoding UTF8))
        if ($entries.Count -eq 0) { continue }

        # 只把"确实能还原点东西"的会话当作候选。
        # 日志里可能存在无法执行的条目（例如备份当时失败了，Existed=false 且没有备份文件），
        # 若不筛掉，用户会在回滚列表里看到一堆点了却什么都没发生的还原点。
        $restorable = 0
        foreach ($e in $entries) {
            $kind   = Get-TrdScalarValue (Get-TrdProp $e 'Kind')
            $backup = Get-TrdScalarValue (Get-TrdProp $e 'Backup')
            $exists = Get-TrdScalarValue (Get-TrdProp $e 'Existed')
            switch ($kind) {
                'RegValue' { $restorable++; break }
                'File'     { if ($exists -and $backup) { $restorable++ }; break }
                'RegKey'   { if ($exists -and $backup) { $restorable++ }; break }
            }
        }
        if ($restorable -eq 0) { continue }

        $null = $out.Add([PSCustomObject]@{
            SessionDir      = $d.FullName
            Name            = $d.Name
            Count           = $entries.Count
            RestorableCount = $restorable
            Entries         = $entries
            Kinds           = @(($entries | Group-Object Kind | ForEach-Object { "$($_.Name)x$($_.Count)" }) -join ',')
        })
    }
    return @($out)
}

function Invoke-TrdRollback {
    <#
    .SYNOPSIS
        回滚最近一次【有实际改动】的备份会话，或指定的会话。
    #>
    [CmdletBinding()]
    param(
        [string]$SessionDir,
        [int]$Skip = 0        # 跳过最近 N 个有内容的会话，用于回滚到更早的还原点
    )

    if (-not $SessionDir) {
        $sessions = @(Get-TrdRollbackSessions)
        if ($sessions.Count -eq 0) {
            Write-TrdLog '没有任何包含实际改动的备份会话，无需回滚。' 'Info'
            Write-TrdLog '（只读体检与演练模式的运行不会产生改动，因此不会留下回滚点。）' 'Detail'
            return
        }
        if ($Skip -ge $sessions.Count) {
            Write-TrdLog "只找到 $($sessions.Count) 个可回滚的会话，无法跳过 $Skip 个。" 'Warn'
            return
        }
        $picked = $sessions[$Skip]
        Write-TrdLog "回滚点: $($picked.Name)  （$($picked.RestorableCount) 项可还原，共 $($picked.Count) 条记录: $($picked.Kinds)）" 'Info'
        if ($sessions.Count -gt 1) {
            Write-TrdLog "更早的回滚点还有 $($sessions.Count - 1) 个，可用 -RollbackSession N 选择（N 从 1 开始）。" 'Detail'
        }
        $SessionDir = $picked.SessionDir
    }

    $jf = Join-Path $SessionDir 'journal.json'
    if (-not (Test-Path -LiteralPath $jf)) {
        Write-TrdLog "该备份会话没有 journal.json: $SessionDir" 'Error'; return
    }

    Write-TrdLog "从以下会话回滚: $SessionDir" 'Step'
    # 必须走 ConvertFrom-TrdJsonArray：直接把管道结果套 @() 会拿到
    # "1 个元素的数组（其元素才是真数组）"，属性访问会全部错位。
    $journal = @(ConvertFrom-TrdJsonArray -Json (Get-Content -LiteralPath $jf -Raw -Encoding UTF8))
    if ($journal.Count -eq 0) {
        Write-TrdLog '该会话没有记录任何改动，无需回滚。' 'Info'; return
    }
    $n = 0

    # 哪些分支有"逐值"记录？这些分支要靠逐值还原，不能再用整体 import ——
    # reg import 只能合并/覆盖，删不掉修复过程中新增的值。
    $pathsWithValueLog = @{}
    foreach ($e in $journal) {
        if ((Get-TrdScalarValue (Get-TrdProp $e 'Kind')) -eq 'RegValue') {
            $t = Get-TrdScalarValue (Get-TrdProp $e 'Target')
            if ($t) { $pathsWithValueLog[$t] = $true }
        }
    }

    # ---- 第一轮：文件还原 与 无逐值记录的分支整体还原 ----
    foreach ($e in $journal) {
        $kind    = Get-TrdScalarValue (Get-TrdProp $e 'Kind')
        $target  = Get-TrdScalarValue (Get-TrdProp $e 'Target')
        $backup  = Get-TrdScalarValue (Get-TrdProp $e 'Backup')
        $existed = Get-TrdScalarValue (Get-TrdProp $e 'Existed')

        switch ($kind) {
            'File' {
                if ($existed -and $backup -and (Test-Path -LiteralPath $backup)) {
                    try {
                        Copy-Item -LiteralPath $backup -Destination $target -Force -ErrorAction Stop
                        Write-TrdLog "还原文件: $target" 'OK'; $n++
                    } catch { Write-TrdLog "还原失败 $target : $($_.Exception.Message)" 'Error' }
                } elseif (-not $existed -and $target -and (Test-Path -LiteralPath $target)) {
                    Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
                    Write-TrdLog "删除新增文件: $target" 'OK'; $n++
                }
            }
            'RegKey' {
                if ($target -and $pathsWithValueLog.ContainsKey($target)) {
                    # 交给逐值还原处理，跳过整体导入
                    continue
                }
                if ($existed -and $backup -and (Test-Path -LiteralPath $backup)) {
                    $code = Invoke-TrdProcess -FilePath (Get-TrdSystemToolPath -Name 'reg.exe') `
                            -Arguments (ConvertTo-TrdArgString @('import', $backup))
                    if ($code -eq 0) { Write-TrdLog "还原注册表分支: $target" 'OK'; $n++ }
                    else { Write-TrdLog "还原注册表分支失败: $target (退出码 $code)" 'Error' }
                } else {
                    Write-TrdLog "跳过 $target （该分支当时没有成功备份，无内容可还原）" 'Detail'
                }
            }
        }
    }

    # ---- 第二轮：逐值精确还原（删除新增值 / 写回旧值与旧类型）----
    foreach ($e in $journal) {
        if ((Get-TrdScalarValue (Get-TrdProp $e 'Kind')) -ne 'RegValue') { continue }
        $target = Get-TrdScalarValue (Get-TrdProp $e 'Target')
        $name   = Get-TrdScalarValue (Get-TrdProp $e 'Name')
        $hadIt  = Get-TrdScalarValue (Get-TrdProp $e 'ExistedBefore')

        if (-not $target -or -not $name) { continue }

        try {
            if ($hadIt) {
                $oldVal  = Get-TrdScalarValue (Get-TrdProp $e 'OldValue')
                $oldKind = Get-TrdScalarValue (Get-TrdProp $e 'OldKind')
                if (-not $oldKind) { $oldKind = 'String' }
                $null = Set-TrdRegValueEx -RegPath $target -Name $name -Value $oldVal -Kind $oldKind
                Write-TrdLog "还原注册表值: $name => $oldVal" 'OK'; $n++
            } else {
                $removed = Remove-TrdRegValueEx -RegPath $target -Name $name
                if ($removed) {
                    Write-TrdLog "删除修复时新增的注册表值: $name" 'OK'; $n++
                } else {
                    Write-TrdLog "注册表值已不存在（可能已被手动清理）: $name" 'Detail'
                }
            }
        } catch {
            Write-TrdLog "还原注册表值失败 $name : $($_.Exception.Message)" 'Error'
        }
    }

    Write-TrdLog "回滚完成，共处理 $n 项。建议重启后再运行游戏。" 'OK'
}

# ---------------------------------------------------------------------------
#  注册表底层访问（.NET API）
#
#  为什么不用 Get-ItemProperty / New-ItemProperty：
#    兼容性标记的【值名】就是 exe 的完整路径，里面含方括号，例如
#        D:\game\[th08] 东方永夜抄 (汉)\vpatch.exe
#    PowerShell 的注册表 cmdlet 会把值名里的 [ ] 当作通配符字符类处理，
#    读取/删除时匹配不到目标值（写入之所以能成功，是因为写入不展开通配符）。
#    直接用 Microsoft.Win32.RegistryKey 可以完全绕开这个问题。
# ---------------------------------------------------------------------------
function Get-TrdRegHive {
    param([Parameter(Mandatory = $true)][string]$RegPath)

    $psPath = ConvertTo-TrdRegPsPath -RegPath $RegPath
    if (-not $psPath) { return $null }
    if ($psPath -notmatch '^([A-Za-z_]+):\\(.*)$') {
        if ($psPath -match '^([A-Za-z_]+):$') {
            return [PSCustomObject]@{ Base = (Get-TrdRegHiveBase -Hive $Matches[1]); SubKey = '' }
        }
        return $null
    }
    $hive = $Matches[1]; $sub = $Matches[2]
    $base = Get-TrdRegHiveBase -Hive $hive
    if (-not $base) { return $null }
    return [PSCustomObject]@{ Base = $base; SubKey = $sub }
}

function Get-TrdRegHiveBase {
    param([string]$Hive)
    switch ($Hive.ToUpperInvariant()) {
        'HKCU' { return [Microsoft.Win32.Registry]::CurrentUser }
        'HKLM' { return [Microsoft.Win32.Registry]::LocalMachine }
        'HKCR' { return [Microsoft.Win32.Registry]::ClassesRoot }
        'HKU'  { return [Microsoft.Win32.Registry]::Users }
        'HKCC' { return [Microsoft.Win32.Registry]::CurrentConfig }
        default { return $null }
    }
}

function Get-TrdRegViewEnum {
    param([string]$View)
    switch ($View) {
        'Registry64' { return [Microsoft.Win32.RegistryView]::Registry64 }
        'Registry32' { return [Microsoft.Win32.RegistryView]::Registry32 }
        default      { return [Microsoft.Win32.RegistryView]::Default }
    }
}

function Get-TrdRegAccess {
    <#
    .SYNOPSIS
        把注册表路径解析成"基键 + 显式视图 + 子键"三件事。
    .DESCRIPTION
        为什么不能直接用 [Microsoft.Win32.Registry]::LocalMachine：
        它的默认视图【等于当前进程的视图】。在 64 位系统上跑 32 位
        PowerShell（WOW64）时，SOFTWARE 会被重定向到 SOFTWARE\WOW6432Node，
        后果是：64 位 VC++ 运行库的卸载记录整个看不见 -> 误报"VC 运行库缺失"，
        进而触发一次完全没有必要的重装。本机实测对照：
            64 位进程：SOFTWARE\Microsoft\Direct3D\Drivers -> 不存在
            32 位进程：同一路径                      -> 存在（其实是 32 位视图那份）
        也就是 32 位进程拿到的是"32 位视图冒充原生视图"，全程不报任何错。
        所以这里一律用 OpenBaseKey 显式指定视图。

        顺带纠正一个此前写错的推断：路径里重复出现 WOW6432Node **不会**
        被再套一层。本机实测：Registry32 视图下 'SOFTWARE\WOW6432Node' 与
        'SOFTWARE' 解析到同一个键，'SOFTWARE\WOW6432Node\WOW6432Node' 不存在。
        注册表 API 在这点上是幂等的，所以旧代码并没有造出假分支（曾被误判为
        严重 bug，已更正）。这里仍然把该段剥掉并转成视图标记，
        目的不是"防止出错"，而是让路径的视图归属变成【显式】的，
        不再依赖那条幂等特性。
    .OUTPUTS
        PSCustomObject: Hive, HiveEnum, SubKey, ViewName, ViewEnum, ForcedX86
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RegPath,
        [ValidateSet('Auto', 'Native', 'X86', 'X64')][string]$View = 'Auto'
    )

    $psPath = ConvertTo-TrdRegPsPath -RegPath $RegPath
    if (-not $psPath) { return $null }
    if ($psPath -notmatch '^([A-Za-z_]+):\\(.*)$') { return $null }
    $hive = $Matches[1]
    $sub  = $Matches[2]

    # 显式写的 WOW6432Node 段 -> 强制 32 位视图，并从子键路径里剥掉
    # （-match 在 PowerShell 里本身就不区分大小写，不需要内联 (?i)）
    $forcedX86 = $false
    if ($sub -match '^SOFTWARE\\WOW6432Node(?:\\(.*))?$') {
        $forcedX86 = $true
        $sub = 'SOFTWARE'
        if ($Matches[1]) { $sub = $sub + '\' + $Matches[1] }
    }

    # 原生视图：未初始化时按进程环境兜底
    $native = [string]$script:TRD.RegViewNative
    if (-not $native) {
        $procArch = [string]$env:PROCESSOR_ARCHITECTURE
        $is64os = ($procArch -eq 'AMD64' -or $procArch -eq 'IA64' -or
                   $procArch -eq 'ARM64' -or [bool]$env:PROCESSOR_ARCHITEW6432)
        $native = if ($is64os) { 'Registry64' } else { 'Registry32' }
    }

    $viewName = switch ($View) {
        'X86'    { 'Registry32' }
        'X64'    { 'Registry64' }
        'Native' { $native }
        default  { if ($forcedX86) { 'Registry32' } else { $native } }
    }
    if (-not $viewName) { $viewName = 'Registry32' }
    # 32 位系统只有一个视图，不存在 64 位视图
    if ($forcedX86 -or -not $script:TRD.Is64OS) { $viewName = 'Registry32' }

    $hiveEnum = switch ($hive.ToUpperInvariant()) {
        'HKCU' { [Microsoft.Win32.RegistryHive]::CurrentUser }
        'HKLM' { [Microsoft.Win32.RegistryHive]::LocalMachine }
        'HKCR' { [Microsoft.Win32.RegistryHive]::ClassesRoot }
        'HKU'  { [Microsoft.Win32.RegistryHive]::Users }
        'HKCC' { [Microsoft.Win32.RegistryHive]::CurrentConfig }
        default { $null }
    }
    if ($null -eq $hiveEnum) { return $null }

    return [PSCustomObject]@{
        Hive      = $hive
        HiveEnum  = $hiveEnum
        SubKey    = $sub
        ViewName  = $viewName
        ViewEnum  = (Get-TrdRegViewEnum -View $viewName)
        ForcedX86 = $forcedX86
    }
}

function Open-TrdRegSubKey {
    <#
    .SYNOPSIS
        按显式视图打开（或创建）注册表子键；返回的对象由调用方 Close()。
    .PARAMETER Create
        分支不存在时创建。
    .PARAMETER Writable
        以可写方式打开。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RegPath,
        [switch]$Create,
        [switch]$Writable,
        [ValidateSet('Auto', 'Native', 'X86', 'X64')][string]$View = 'Auto'
    )

    $a = Get-TrdRegAccess -RegPath $RegPath -View $View
    if (-not $a) { return $null }

    $base = $null
    $ownedBase = $false
    try {
        try {
            $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey($a.HiveEnum, $a.ViewEnum)
            $ownedBase = $true
        } catch {
            # .NET 4.0 以下没有 OpenBaseKey；此时基本只会是 32 位系统，退回默认基键
            $base = Get-TrdRegHiveBase -Hive $a.Hive
        }
        if (-not $base) { return $null }
        if ($Create) { return $base.CreateSubKey($a.SubKey) }
        return $base.OpenSubKey($a.SubKey, [bool]$Writable)
    } finally {
        # 基键句柄用完即关。子键是独立句柄（RegOpenKeyEx 产生），不受影响。
        if ($ownedBase -and $base) { try { $base.Close() } catch { } }
    }
}

function Get-TrdRegValueEx {
    <#
    .SYNOPSIS
        读取一个注册表值的"存在性 + 当前值 + 类型"。值名可含 [ ]。
    .OUTPUTS
        PSCustomObject: Exists, Value, Kind
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RegPath,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $r = [PSCustomObject]@{ Exists = $false; Value = $null; Kind = $null }

    $k = $null
    try {
        $k = Open-TrdRegSubKey -RegPath $RegPath
        if (-not $k) { return $r }
        $names = @($k.GetValueNames())
        if ($names -notcontains $Name) { return $r }
        $r.Exists = $true
        $r.Value = $k.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $r.Kind = $k.GetValueKind($Name).ToString()
    } catch {
    } finally {
        if ($k) { $k.Close() }
    }
    return $r
}

function Set-TrdRegValueEx {
    <#
    .SYNOPSIS
        写一个注册表值。值名可含 [ ]。分支不存在时自动创建。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RegPath,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][object]$Value,
        [string]$Kind = 'String'
    )

    $k = Open-TrdRegSubKey -RegPath $RegPath -Create   # Create 会在需要时创建分支
    if (-not $k) { throw "无法打开/创建注册表分支: $RegPath" }
    try {
        $vk = switch ($Kind) {
            'ExpandString' { [Microsoft.Win32.RegistryValueKind]::ExpandString }
            'DWord'        { [Microsoft.Win32.RegistryValueKind]::DWord }
            'QWord'        { [Microsoft.Win32.RegistryValueKind]::QWord }
            'MultiString'  { [Microsoft.Win32.RegistryValueKind]::MultiString }
            'Binary'       { [Microsoft.Win32.RegistryValueKind]::Binary }
            default        { [Microsoft.Win32.RegistryValueKind]::String }
        }
        $k.SetValue($Name, $Value, $vk)
    } finally {
        $k.Close()
    }
    return $true
}

function Remove-TrdRegValueEx {
    <#
    .SYNOPSIS
        删除一个注册表值（不存在则静默返回）。值名可含 [ ]。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RegPath,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $k = $null
    try {
        $k = Open-TrdRegSubKey -RegPath $RegPath -Writable
        if (-not $k) { return $false }
        if (@($k.GetValueNames()) -contains $Name) {
            $k.DeleteValue($Name, $false)
            return $true
        }
        return $false
    } finally {
        if ($k) { $k.Close() }
    }
}

function Set-TrdRegValue {
    <#
    .SYNOPSIS
        安全地写注册表值：先记录修改前状态（逐值），再写入。
    .DESCRIPTION
        逐值记录是必需的。只靠 reg export 做整体备份是【不完备】的：
        reg import 只能合并/覆盖，无法删除"修复过程中新增的值"，
        于是回滚后新增的项会残留，用户以为已经还原、其实没有。
        因此这里额外记一条 RegValue 日志：原本不存在 -> 回滚时删除；
        原本存在 -> 回滚时写回原值与原类型。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RegPath,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][object]$Value,
        [ValidateSet('String', 'ExpandString', 'DWord', 'QWord', 'MultiString', 'Binary')]
        [string]$Type = 'String',
        [string]$BackupTag = 'regwrite'
    )

    if ($script:TRD.DryRun) {
        Write-TrdLog "[演练] 将写入注册表 $RegPath :: $Name = $Value" 'Info'
        return $true
    }

    $normPath = ConvertTo-TrdRegExePath -RegPath $RegPath

    # 1) 整个分支导出一次，作为人工可读的快照与最后兜底
    $already = @($script:TRD.Journal | Where-Object { $_.Kind -eq 'RegKey' -and $_.Target -eq $normPath }).Count -gt 0
    if (-not $already) {
        $bk = Backup-TrdRegKey -RegPath $RegPath -Tag $BackupTag
        if ($bk -and -not $bk.Ok) {
            Write-TrdLog "注意：[$normPath] 没有生成整体回滚快照。" 'Warn'
        }
    }

    # 2) 逐值快照 —— 回滚时真正依赖的就是这一条
    $prev = Get-TrdRegValueEx -RegPath $RegPath -Name $Name
    $null = $script:TRD.Journal.Add([PSCustomObject]@{
        Kind          = 'RegValue'
        Target        = $normPath
        Name          = $Name
        ExistedBefore = [bool]$prev.Exists
        OldValue      = $(if ($prev.Exists) { $prev.Value } else { $null })
        OldKind       = $(if ($prev.Exists) { $prev.Kind } else { $null })
    })

    try {
        $null = Set-TrdRegValueEx -RegPath $RegPath -Name $Name -Value $Value -Kind $Type
        return $true
    } catch {
        Write-TrdLog "写注册表失败 $RegPath\$Name : $($_.Exception.Message)" 'Warn'
        return $false
    }
}

function Get-TrdRegValue {
    param([string]$RegPath, [string]$Name)
    $v = Get-TrdRegValueEx -RegPath $RegPath -Name $Name
    if ($v.Exists) { return $v.Value }
    return $null
}

# ---------------------------------------------------------------------------
#  离线载荷
# ---------------------------------------------------------------------------
function Get-TrdOfflineManifest {
    <#
    .SYNOPSIS
        读取 offline/packages.json 载荷清单；不存在时返回内置缺省结构。
    #>
    [CmdletBinding()]
    param([string]$OfflineRoot)

    if (-not $OfflineRoot) { $OfflineRoot = $script:TRD.OfflineRoot }
    $path = Join-Path $OfflineRoot 'packages.json'
    if (-not (Test-Path -LiteralPath $path)) {
        return [PSCustomObject]@{ Version = 1; Packages = @() }
    }
    try {
        $raw = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
        # 用 -InputObject 而不是管道：管道会把顶层数组当成单个对象输出，@() 不展开
        return (ConvertFrom-Json -InputObject $raw)
    } catch {
        Write-TrdLog "载荷清单解析失败: $($_.Exception.Message)" 'Warn'
        return [PSCustomObject]@{ Version = 1; Packages = @() }
    }
}

function Find-TrdOfflinePackage {
    <#
    .SYNOPSIS
        在离线载荷目录里按"候选文件名 + 相对路径"查找一个包。
    .DESCRIPTION
        查找顺序：清单声明的相对路径 -> 载荷根 -> 载荷根下任意深度同名文件。
        找到后若清单给了 SHA256 则校验，返回对象里带 HashOk 字段。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Package,
        [string]$OfflineRoot
    )

    if (-not $OfflineRoot) { $OfflineRoot = $script:TRD.OfflineRoot }
    if (-not (Test-Path -LiteralPath $OfflineRoot)) {
        return [PSCustomObject]@{ Found = $false; Path = $null; HashOk = $null; Reason = '离线载荷目录不存在' }
    }

    $candidates = New-Object System.Collections.ArrayList
    if ($Package.PSObject.Properties.Name -contains 'Files' -and $Package.Files) {
        foreach ($f in $Package.Files) { $null = $candidates.Add($f) }
    }
    if ($Package.PSObject.Properties.Name -contains 'File' -and $Package.File) {
        $null = $candidates.Add($Package.File)
    }
    # ZipGlobs 也必须纳入候选：像 dgVoodoo2 / Locale Emulator 这类压缩包工具，
    # 清单里只能用通配符描述（版本号会变），没有固定的 Files 条目。
    if ($Package.PSObject.Properties.Name -contains 'ZipGlobs' -and $Package.ZipGlobs) {
        foreach ($g in $Package.ZipGlobs) { $null = $candidates.Add($g) }
    }

    $hit = $null
    foreach ($c in $candidates) {
        if (-not $c) { continue }
        if ($c -match '\*' -or $c -match '\?') {
            # 含通配符：必须用 -Path（非 Literal）才能展开，-LiteralPath 会把 * 当普通字符
            try {
                $pat = Join-Path $OfflineRoot $c
                $found = Get-ChildItem -Path $pat -File -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($found) { $hit = $found.FullName; break }
            } catch { }
        } else {
            $p = Join-Path $OfflineRoot $c
            if (Test-Path -LiteralPath $p -PathType Leaf) { $hit = $p; break }
        }
    }

    if (-not $hit) {
        # 兜底：全目录按文件名搜（用户可能把安装包随手丢进 offline\）
        foreach ($c in $candidates) {
            if (-not $c) { continue }
            $leaf = Split-Path -Leaf $c
            if (-not $leaf) { continue }
            $leaf = $leaf -replace '\*', '' -replace '\?', ''
            if (-not $leaf) { continue }
            $found = Get-ChildItem -LiteralPath $OfflineRoot -Recurse -File -Filter $leaf -ErrorAction SilentlyContinue |
                     Select-Object -First 1
            if ($found) { $hit = $found.FullName; break }
        }
    }

    if (-not $hit) {
        return [PSCustomObject]@{ Found = $false; Path = $null; HashOk = $null; Reason = '载荷中未找到该文件' }
    }

    # SHA256 校验（清单里写了才校验）
    $hashOk = $null
    $expected = $null
    if ($Package.PSObject.Properties.Name -contains 'Sha256') { $expected = $Package.Sha256 }
    if ($expected) {
        try {
            $actual = Get-TrdFileHashSafe -Path $hit
            $hashOk = ($actual -ieq $expected)
        } catch { $hashOk = $null }
    }

    return [PSCustomObject]@{
        Found  = $true
        Path   = $hit
        HashOk = $hashOk
        SizeMB = [Math]::Round((Get-Item -LiteralPath $hit).Length / 1MB, 1)
        Reason = $null
    }
}

function Test-TrdOfflineAvailable {
    <#
    .SYNOPSIS
        判断离线载荷是否基本可用（至少存在目录 + 清单）。
    #>
    if (-not $script:TRD.OfflineRoot) { return $false }
    if (-not (Test-Path -LiteralPath $script:TRD.OfflineRoot)) { return $false }
    $any = Get-ChildItem -LiteralPath $script:TRD.OfflineRoot -Recurse -File -ErrorAction SilentlyContinue |
           Where-Object { $_.Name -ne 'packages.json' -and $_.Name -ne 'README.txt' } |
           Select-Object -First 1
    return [bool]$any
}

# ---------------------------------------------------------------------------
#  杂项工具
# ---------------------------------------------------------------------------
function Test-TrdPathIsAscii {
    <#
    .SYNOPSIS
        判断路径是否全部为 ASCII 可打印字符（东方老引擎在非中文区域下容易在此翻车）。
    #>
    param([Parameter(Mandatory = $true)][string]$Path)
    foreach ($ch in $Path.ToCharArray()) {
        if ([int][char]$ch -gt 126 -or [int][char]$ch -lt 32) { return $false }
    }
    return $true
}

function Get-TrdFreeSpaceMB {
    param([string]$Path)
    try {
        $root = [System.IO.Path]::GetPathRoot((Resolve-Path -LiteralPath $Path).Path)
        $d = New-Object System.IO.DriveInfo($root)
        return [Math]::Round($d.AvailableFreeSpace / 1MB, 0)
    } catch { return $null }
}

function Test-TrdWritable {
    <#
    .SYNOPSIS
        用真实打开文件的方式测试目录可写性（比检查 ACL 可靠）。
    #>
    param([Parameter(Mandatory = $true)][string]$Dir)
    $probe = Join-Path $Dir ('.trd_write_test_{0}.tmp' -f ([guid]::NewGuid().ToString('N').Substring(0, 8)))
    try {
        $fs = [System.IO.File]::Create($probe)
        $fs.WriteByte(0x54); $fs.Close()
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        return $true
    } catch {
        if (Test-Path -LiteralPath $probe) { Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue }
        return $false
    }
}

function Get-TrdWindowsBuild {
    <#
    .SYNOPSIS
        取 Windows 版本信息（用于判断 d3d8 等组件是否原生存在）。
    #>
    $r = [PSCustomObject]@{
        Caption = ''; Version = ''; Build = 0; BuildNumber = 0; Arch = $env:PROCESSOR_ARCHITECTURE
        Is64OS = $false; ProductName = ''; ServicePack = ''; IsWin7 = $false
        IsWin7Sp1 = $false; IsWin8OrNewer = $false
    }
    # Get-TrdWmiObject 内部会按 PowerShell 版本选 Get-CimInstance 或 Get-WmiObject，
    # Win7 上如果没装 WMF3 就只有后者可用。
    $os = Get-TrdWmiObject -ClassName 'Win32_OperatingSystem'
    $wmiArch = $null
    if ($os) {
        try {
            $r.Caption = [string]$os.Caption
            $r.Version = [string]$os.Version
            $r.Build = [int]$os.BuildNumber
            $r.BuildNumber = [int]$os.BuildNumber
            $wmiArch = [string]$os.OSArchitecture
            $r.Arch = $wmiArch
            $r.ServicePack = [string]$os.ServicePackMajorVersion
        } catch { }
    }

    # 位数的权威来源是 Initialize-TrdEnvironment 里基于进程环境算出的结果
    # （它同时考虑 PROCESSOR_ARCHITECTURE 与 PROCESSOR_ARCHITEW6432，
    #  在"64 位系统上跑 32 位 PowerShell"这种情形下仍然正确）。
    # WMI 的 OSArchitecture 只作为兜底：一旦两处结论不一致，
    # 依赖检查与运行环境结论就会自相矛盾，所以这里必须统一口径。
    $r.Is64OS = [bool]$script:TRD.Is64OS
    if ($wmiArch -and -not $script:TRD.Is64OS -and ($wmiArch -match '64')) {
        # 极少见：进程环境没识别出 64 位，但 WMI 明确说是 64 位 —— 以 WMI 为准
        $r.Is64OS = $true
    }
    if ($wmiArch) { $r.Arch = $wmiArch }

    try {
        $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
        $r.ProductName = [string]$cv.ProductName
        if (-not $r.Build) { $r.Build = [int]$cv.CurrentBuildNumber }
        if (-not $r.BuildNumber) { $r.BuildNumber = [int]$cv.CurrentBuildNumber }
    } catch { }

    # Build 7600/7601 = Windows 7 RTM / SP1；7601 以上才在 Win8 时代
    if ($r.Build -gt 0) {
        $r.IsWin7 = ($r.Build -ge 7600 -and $r.Build -le 7601)
        $r.IsWin7Sp1 = ($r.Build -eq 7601)
        $r.IsWin8OrNewer = ($r.Build -ge 9200)
    }
    return $r
}

function Get-TrdSystemLocale {
    <#
    .SYNOPSIS
        取系统 ANSI/OEM 代码页，用于判断东方老引擎的文本编码是否匹配。
    #>
    $r = [PSCustomObject]@{ ACP = 0; OEMCP = 0; Name = ''; Utf8Beta = $false }
    try {
        $cp = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Nls\CodePage' -ErrorAction Stop
        $r.ACP = [int]$cp.ACP; $r.OEMCP = [int]$cp.OEMCP
    } catch { }
    $map = @{ 936 = '简体中文 (GBK)'; 950 = '繁体中文 (Big5)'; 932 = '日语 (Shift-JIS)';
              949 = '韩语'; 1252 = '西欧 (Latin-1)'; 65001 = 'UTF-8 (Beta)' }
    if ($map.ContainsKey($r.ACP)) { $r.Name = $map[$r.ACP] } else { $r.Name = "代码页 $($r.ACP)" }
    if ($r.ACP -eq 65001) { $r.Utf8Beta = $true }
    return $r
}

function Show-TrdProgressBar {
    param([int]$Percent, [string]$Activity)
    try {
        Write-Progress -Activity $Activity -PercentComplete $Percent -Status "$Percent%"
    } catch { }
}
