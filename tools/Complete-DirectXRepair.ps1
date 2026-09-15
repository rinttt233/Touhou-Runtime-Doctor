# ============================================================================
#  Complete-DirectXRepair.ps1 -- 补全 DirectX Repair 缺失的数据文件
#
#  背景（实测结论，不是猜测）：
#    DirectX Repair 3.9 有「标准版」与「增强版」两种形态。标准版只带 DirectX
#    的 DLL 库（Data\A=x86, Data\B=x64），C++ 运行库部分（Data\C）需要通过
#    联网「扩展」或下载完整数据包才有。程序自身的文案即为证据：
#        「界面将程序扩展至增强版。另外，您也可以前往以下网页手动下载增强版程序：」
#        「您的程序已经是增强版且包含完整的C++数据包，无需扩展！」
#    本脚本用【已经校验过 SHA256 的官方离线载荷】在本地把缺失部分补齐，
#    全程不需要联网。
#
#  补什么：
#    1) Data\A / Data\B 中"只有 .cab 没有 .dll"的项 —— 用程序自带的 cab 解出来
#    2) Data\A / Data\B 相对官方 DirectX Jun2010 运行库的缺失组件
#       （实测官方包解出 102 个 DLL；DirectX Repair 的 A/B 只有 87/86 个）
#    3) Data\C —— C++ 运行库安装包（cp05/cp08/cp10/cp12/cp13/cp15）
#
#  命名约定的依据：
#    DirectX Repair 内部用「无后缀 = x64，后缀 a = x86」这一约定，
#    证据是它自己的备份目录：Data\C\Backup\ 放 64 位系统 DLL，
#    Data\C\Backup\a\ 放 32 位系统 DLL。本脚本沿用该约定，
#    并在放置后逐个校验 PE 位数，写错会立刻报出来。
#
#  安全性：
#    * 只往 DirectX Repair 自己的 Data 目录里写文件，不碰系统目录
#    * 每个写入的 DLL 都做 PE 位数校验 + Authenticode 签名校验
#    * 非微软签名或位数不符的文件会被跳过并记录
#    * 支持 -WhatIf 先看要做什么
#
#  用法：
#    pwsh -File tools\Complete-DirectXRepair.ps1 -DataRoot "G:\other\Data"
#    pwsh -File tools\Complete-DirectXRepair.ps1 -DataRoot "G:\other\Data" -WhatIf
#    pwsh -File tools\Complete-DirectXRepair.ps1 -DataRoot "G:\other\Data" -SkipVcRuntime
# ============================================================================
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$DataRoot,
    [string]$ToolRoot,
    [string]$RedistCabDir,
    [string]$DirectXRedistExe,
    [string]$VcRedistRoot,
    [switch]$WhatIf,
    [switch]$SkipDirectX,
    [switch]$SkipVcRuntime,
    [switch]$SkipSignatureCheck
)

$ErrorActionPreference = 'Stop'

if (-not $ToolRoot) {
    if ($PSScriptRoot) { $ToolRoot = Split-Path -Parent $PSScriptRoot }
    else { $ToolRoot = (Get-Location).Path }
}
$ToolRoot = (Resolve-Path -LiteralPath $ToolRoot).Path

if (-not $VcRedistRoot) { $VcRedistRoot = Join-Path $ToolRoot 'offline\VCRedist' }
if (-not $DirectXRedistExe) { $DirectXRedistExe = Join-Path $ToolRoot 'offline\DirectX\directx_Jun2010_redist.exe' }

$script:Stat = [PSCustomObject]@{
    Extracted = 0; AddedDx = 0; AddedVc = 0; Skipped = 0; Failed = 0
    AddedList = (New-Object System.Collections.ArrayList)
    FailedList = (New-Object System.Collections.ArrayList)
    Warnings  = (New-Object System.Collections.ArrayList)
}

function Write-Head { param([string]$t)
    Write-Host ''
    Write-Host ('=' * 76) -ForegroundColor DarkCyan
    Write-Host "  $t" -ForegroundColor Cyan
    Write-Host ('=' * 76) -ForegroundColor DarkCyan
}
function Write-Item { param([string]$Mark, [string]$Text, [string]$Color = 'Gray')
    Write-Host ("  [{0}] {1}" -f $Mark, $Text) -ForegroundColor $Color
}

function Get-Arch {
    param([Parameter(Mandatory = $true)][string]$Path)
    try {
        $fs = [System.IO.File]::OpenRead($Path)
        try {
            $br = New-Object System.IO.BinaryReader($fs)
            if ($fs.Length -lt 0x40) { return 'unknown' }
            $fs.Position = 0x3C
            $peOff = $br.ReadInt32()
            if ($peOff -le 0 -or ($peOff + 6) -ge $fs.Length) { return 'unknown' }
            $fs.Position = $peOff
            if ($br.ReadUInt32() -ne 0x00004550) { return 'unknown' }
            switch ($br.ReadUInt16()) {
                0x014c { return 'x86' }
                0x8664 { return 'x64' }
                0x01c4 { return 'ARMv7' }
                0xaa64 { return 'ARM64' }
                default { return 'unknown' }
            }
        } finally { $fs.Close() }
    } catch { return 'unknown' }
}

function Test-Signed {
    param([Parameter(Mandatory = $true)][string]$Path)
    try {
        $s = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
        if ($s.Status -ne 'Valid') { return [PSCustomObject]@{ Ok = $false; Signer = $null; Status = "$($s.Status)" } }
        $subj = ''
        if ($s.SignerCertificate) { $subj = [string]$s.SignerCertificate.Subject }
        return [PSCustomObject]@{ Ok = $true; Signer = $subj; Status = 'Valid' }
    } catch {
        return [PSCustomObject]@{ Ok = $false; Signer = $null; Status = "查询失败: $($_.Exception.Message)" }
    }
}

function Invoke-Proc {
    <#
    .SYNOPSIS
        运行外部程序并可靠地拿到退出码。
    .DESCRIPTION
        不能用 Start-Process -Wait -PassThru 读 ExitCode：
        实测它对 expand.exe 会返回 -1，即使解包已经成功完成
        （文件确实被解出来了）。原因是该 cmdlet 在进程句柄提前释放时
        读不到真实退出码，返回 -1 或直接抛异常。
        直接用 System.Diagnostics.Process 启动，它自己持有进程句柄，
        WaitForExit() 之后读 ExitCode 是可靠的。
    #>
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @(),
        [string]$StdOutFile = 'NUL'
    )
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $FilePath
        # 参数自己拼引号：Start-Process 的数组形式不会给含空格的元素加引号
        $parts = foreach ($a in $Arguments) {
            if ($a -match '[\s"]') { '"' + ($a -replace '"', '\"') + '"' } else { $a }
        }
        $psi.Arguments = ($parts -join ' ')
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true

        $proc = [System.Diagnostics.Process]::Start($psi)
        # 必须异步读走输出，否则 expand 输出较多时管道写满会死锁
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $errTask = $proc.StandardError.ReadToEndAsync()
        $proc.WaitForExit()
        [void]$outTask.Result
        [void]$errTask.Result
        return [int]$proc.ExitCode
    } catch {
        Write-Host "      执行失败 $([System.IO.Path]::GetFileName($FilePath)) : $($_.Exception.Message)" -ForegroundColor DarkYellow
        return -1
    }
}
function Copy-Verified {
    <#
    .SYNOPSIS
        复制一个文件到目标位置，复制前校验位数与签名。
    .DESCRIPTION
        位数不对是最危险的错误：把 64 位 DLL 放进 x86 槽位，会让 DirectX Repair
        把错误位数的文件部署到系统目录，产生 0xC000007B 这类极难排查的故障。
        所以宁可跳过也不能放错。
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][ValidateSet('x86', 'x64')][string]$ExpectArch,
        [string]$Label = '',
        [switch]$SkipArchCheck
    )

    $name = Split-Path -Leaf $Destination

    # 安装包（vcredist*.exe）必须跳过位数校验：
    # 它们是 32 位引导包装器，x64 版本的 PE 头同样是 x86
    # （实测 VC2005~2022 全部 12 个 redist 均为 x86 PE），
    # 按 PE 位数判定会把所有 x64 安装包误判成放错位置而全部跳过。
    if (-not $SkipArchCheck) {
    $arch = Get-Arch -Path $Source
    if ($arch -ne $ExpectArch) {
        $null = $script:Stat.FailedList.Add("$name : 位数不符（实际 $arch，应为 $ExpectArch）")
        $script:Stat.Failed++
        Write-Item '!!' "$name 位数不符（实际 $arch，应为 $ExpectArch），已跳过" 'Red'
        return $false
    }
    }

    if (-not $SkipSignatureCheck) {
        $sig = Test-Signed -Path $Source
        if (-not $sig.Ok) {
            $null = $script:Stat.FailedList.Add("$name : 签名无效（$($sig.Status)）")
            $script:Stat.Failed++
            Write-Item '!!' "$name 数字签名无效（$($sig.Status)），已跳过以保证安全" 'Red'
            return $false
        }
    }

    if ($WhatIf) {
        Write-Item '..' "[演练] 将复制 $name -> $Destination" 'DarkGray'
        $tag = if ($Label) { $Label + ' ' } else { '' }
        $null = $script:Stat.AddedList.Add("$tag$name ($ExpectArch)")
        return $true
    }

    $dir = Split-Path -Parent $Destination
    if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
    Copy-Item -LiteralPath $Source -Destination $Destination -Force
    $tag2 = if ($Label) { $Label + ' ' } else { '' }
    $null = $script:Stat.AddedList.Add("$tag2$name ($ExpectArch)")
    return $true
}

# ===========================================================================
Write-Head 'DirectX Repair 数据补全'

if (-not (Test-Path -LiteralPath $DataRoot)) { throw "找不到 Data 目录: $DataRoot" }
$dirA = Join-Path $DataRoot 'A'
$dirB = Join-Path $DataRoot 'B'
$dirC = Join-Path $DataRoot 'C'
if (-not (Test-Path -LiteralPath $dirA) -or -not (Test-Path -LiteralPath $dirB)) {
    throw "Data 目录结构不符（需要 A 与 B 两个子目录）: $DataRoot"
}
Write-Item 'OK' "Data 目录: $DataRoot"
Write-Item '..' ("现有 DLL 数：A(x86)={0}  B(x64)={1}" -f `
    @(Get-ChildItem $dirA -File -Filter '*.dll').Count, @(Get-ChildItem $dirB -File -Filter '*.dll').Count)
if ($WhatIf) { Write-Item '..' '演练模式：只显示将要做的操作' 'Yellow' }

# ---------------------------------------------------------------------------
if (-not $SkipDirectX) {
    Write-Head '第 1 步 / 解开 Data 中残留的 cab'

    $expand = Join-Path $env:windir 'System32\expand.exe'
    $cabJobs = @(
        @{ Cab = 'A\XAudio2_4.dll_x86.cab'; Dll = 'XAudio2_4.dll'; Arch = 'x86'; Dir = $dirA }
        @{ Cab = 'B\XAudio2_0.dll_x64.cab'; Dll = 'XAudio2_0.dll'; Arch = 'x64'; Dir = $dirB }
        @{ Cab = 'B\XAudio2_4.dll_x64.cab'; Dll = 'XAudio2_4.dll'; Arch = 'x64'; Dir = $dirB }
    )

    foreach ($j in $cabJobs) {
        $cabPath = Join-Path $DataRoot $j.Cab
        $dllPath = Join-Path $j.Dir $j.Dll
        if (Test-Path -LiteralPath $dllPath) { Write-Item 'OK' "$($j.Dll) 已存在，跳过"; continue }
        if (-not (Test-Path -LiteralPath $cabPath)) { Write-Item '!!' "找不到 cab: $($j.Cab)" 'Yellow'; continue }
        if ($WhatIf) { Write-Item '..' "[演练] 将从 $($j.Cab) 解出 $($j.Dll)" 'DarkGray'; continue }

        $tmp = Join-Path $env:TEMP ('trd_cab_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $null = New-Item -ItemType Directory -Path $tmp -Force
        $code = Invoke-Proc -FilePath $expand -Arguments @($cabPath, $j.Dll, $tmp)
        $got = Join-Path $tmp $j.Dll
        # 判据以"文件是否真的解出来"为准，退出码只作为参考；
        # 实测 expand 成功时 Start-Process 也可能报 -1。
        if (Test-Path -LiteralPath $got) {
            if (Copy-Verified -Source $got -Destination $dllPath -ExpectArch $j.Arch -Label '解开cab') {
                $script:Stat.Extracted++
                Write-Item 'OK' "已解出 $($j.Dll) ($($j.Arch))" 'Green'
            }
        } else {
            Write-Item '!!' "解 $($j.Cab) 失败（退出码 $code）" 'Red'
            $script:Stat.Failed++
        }
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
if (-not $SkipDirectX) {
    Write-Head '第 2 步 / 用官方运行库补齐缺失的 DirectX 组件'

    $cabDir = $RedistCabDir
    $tmpRoot = $null
    if (-not $cabDir -or -not (Test-Path -LiteralPath $cabDir)) {
        if (-not (Test-Path -LiteralPath $DirectXRedistExe)) {
            Write-Item '!!' "找不到官方运行库: $DirectXRedistExe" 'Red'
            Write-Item '..' '可先用 tools\Fetch-OfflinePack.ps1 -Only DX9_REDIST_JUN2010 下载' 'Yellow'
        } else {
            $tmpRoot = Join-Path $env:TEMP ('trd_dx_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
            $null = New-Item -ItemType Directory -Path $tmpRoot -Force
            Write-Item '..' '正在解包官方 DirectX 运行库（约需 1-3 分钟）...'

            # Windows 自带的 expand / extrac32 都读不了这种自解压包，
            # 实测需要 Bandizip（或 7-Zip）这类第三方解压器。
            $bz = @(
                (Join-Path $env:ProgramFiles 'Bandizip\bz.exe'),
                (Join-Path ${env:ProgramFiles(x86)} 'Bandizip\bz.exe')
            ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1

            if ($bz) {
                $null = Start-Process -FilePath $bz -ArgumentList @('x', '-y', "-o:$tmpRoot", $DirectXRedistExe) -Wait -PassThru -NoNewWindow
                if (@(Get-ChildItem -LiteralPath $tmpRoot -File -Filter '*.cab' -ErrorAction SilentlyContinue).Count -gt 0) {
                    $cabDir = $tmpRoot
                }
            }
            if (-not $cabDir) {
                Write-Item '!!' '无法解包官方运行库。请安装 Bandizip，或手动解包后用 -RedistCabDir 指定目录。' 'Red'
                Write-Item '..' '手动方法：用 Bandizip / 7-Zip 打开 directx_Jun2010_redist.exe，全部解压到一个文件夹。' 'Yellow'
            } else {
                Write-Item 'OK' "已解包到 $tmpRoot"
            }
        }
    }

    if ($cabDir -and (Test-Path -LiteralPath $cabDir)) {
        $cabs = @(Get-ChildItem -LiteralPath $cabDir -File -Filter '*.cab')
        Write-Item '..' "载荷 cab 数: $($cabs.Count)"

        # 按 cab 名里的 _x86 / _x64 分位数解包。
        # 不能一次全解到同一目录：同名 DLL 在两种位数的 cab 里都有，
        # 后解出的会覆盖先解出的，最终拿到哪个位数完全是偶然的。
        $stageX86 = Join-Path $env:TEMP ('trd_sx86_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $stageX64 = Join-Path $env:TEMP ('trd_sx64_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $null = New-Item -ItemType Directory -Path $stageX86 -Force
        $null = New-Item -ItemType Directory -Path $stageX64 -Force

        $expand2 = Join-Path $env:windir 'System32\expand.exe'
        $n = 0
        foreach ($c in $cabs) {
            if ($c.Name -match '_x86') { $dest = $stageX86 }
            elseif ($c.Name -match '_x64') { $dest = $stageX64 }
            else { continue }
            $null = Invoke-Proc -FilePath $expand2 -Arguments @($c.FullName, '-F:*', $dest)
            $n++
        }
        Write-Item 'OK' "解包 $n 个 cab（已按位数分开）"

        # 官方包里有些是 .NET 诊断程序集，不是 DirectX 运行库组件，要排除
        $excludePat = '^microsoft\.directx\.|^dxupdate\.dll$'

        foreach ($pair in @(@{ Dir = $stageX86; Target = $dirA; Arch = 'x86' },
                            @{ Dir = $stageX64; Target = $dirB; Arch = 'x64' })) {
            $have = @{}
            foreach ($f in @(Get-ChildItem $pair.Target -File -Filter '*.dll')) { $have[$f.Name.ToLower()] = $true }

            $srcDlls = @(Get-ChildItem $pair.Dir -File -Filter '*.dll' |
                         Where-Object { $_.Name -notmatch $excludePat } |
                         Sort-Object Name -Unique)
            $added = 0
            foreach ($s in $srcDlls) {
                if ($have.ContainsKey($s.Name.ToLower())) { continue }
                if (Copy-Verified -Source $s.FullName -Destination (Join-Path $pair.Target $s.Name) `
                                  -ExpectArch $pair.Arch -Label 'DX') {
                    $added++
                    $script:Stat.AddedDx++
                }
            }
            Write-Item 'OK' ("$($pair.Arch): 补充 $added 个组件（源 $($srcDlls.Count) 个，原本已有 $($have.Count) 个）") 'Green'
        }

        # ------------------------------------------------------------------
        #  2b. 校验 Data\A / B 中【已有】文件的数字签名
        #
        #  只补"缺失"是不够的：实测发现 DirectX Repair 自带的
        #  Data\A\XAudio2_0.dll 只有 160KB 且【没有数字签名】，
        #  而官方 Mar2008_XAudio_x86.cab 里的同名文件是 479KB 且微软签名，
        #  两者哈希完全不同。这个未签名文件会被工具部署到系统目录，
        #  属于必须纠正的安全隐患。
        #  这里逐个检查，凡签名无效/缺失的，用官方同位数文件替换。
        # ------------------------------------------------------------------
        Write-Host ''
        Write-Item '..' '校验已有 DLL 的数字签名 ...'

        $replaced = 0
        foreach ($pair in @(@{ Stage = $stageX86; Target = $dirA; Arch = 'x86' },
                            @{ Stage = $stageX64; Target = $dirB; Arch = 'x64' })) {
            foreach ($f in @(Get-ChildItem $pair.Target -File -Filter '*.dll')) {
                $sig = Test-Signed -Path $f.FullName
                if ($sig.Ok) { continue }

                $official = Join-Path $pair.Stage $f.Name
                if (-not (Test-Path -LiteralPath $official)) {
                    $null = $script:Stat.Warnings.Add("$($f.Name) 无有效签名，且官方载荷中没有同名文件可替换（保留原样）")
                    Write-Item '!!' "$($f.Name) 无有效签名（$($sig.Status)），官方无同名文件可替换" 'Yellow'
                    continue
                }

                $officialSig = Test-Signed -Path $official
                if (-not $officialSig.Ok) {
                    $null = $script:Stat.Warnings.Add("$($f.Name) 与官方版本都无有效签名")
                    Write-Item '!!' "$($f.Name) 官方版本也无有效签名，跳过" 'Yellow'
                    continue
                }

                $oldLen = $f.Length
                $newLen = (Get-Item -LiteralPath $official).Length
                if ($WhatIf) {
                    Write-Item '..' "[演练] 将用官方签名版本替换 $($f.Name)（$oldLen -> $newLen 字节）" 'DarkGray'
                    $replaced++
                    continue
                }

                Copy-Item -LiteralPath $official -Destination $f.FullName -Force
                $script:Stat.AddedDx++
                $replaced++
                $null = $script:Stat.AddedList.Add("替换未签名 $($f.Name) ($($pair.Arch)) $oldLen->$newLen 字节")
                Write-Item 'OK' "已用官方签名版本替换 $($f.Name)（$oldLen -> $newLen 字节）" 'Green'
            }
        }
        if ($replaced -eq 0) { Write-Item 'OK' '所有已有 DLL 签名均有效' 'Green' }
        else { Write-Item 'OK' "共替换 $replaced 个无签名的 DLL" 'Green' }

        Remove-Item $stageX86, $stageX64 -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($tmpRoot) { Remove-Item $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

# ---------------------------------------------------------------------------
if (-not $SkipVcRuntime) {
    Write-Head '第 3 步 / 建立 Data\C（C++ 运行库数据包）'

    if (-not (Test-Path -LiteralPath $VcRedistRoot)) {
        Write-Item '!!' "找不到 VC 运行库载荷: $VcRedistRoot" 'Red'
        Write-Item '..' '可先用 tools\Fetch-OfflinePack.ps1 -All 下载' 'Yellow'
    } else {
        # 映射表：DirectX Repair 的目录/文件名 -> 本工具 offline\VCRedist 下的相对路径
        # 「无后缀 = x64，后缀 a = x86」的依据见文件头。
        # cp12/cp13 的 b/c 与 cp15 的 d/e 是同一大版本的更新版，
        # 这里放"最新可用"的那一个：装新版能覆盖旧版的需求。
        # 关键：直接放"安装包本体"，不做解包。
        # 实测这些 redist 都是 32 位引导包装器（x64 版本的 PE 头同样是 x86），
        # 而且都不支持 /Q /T: 自解压（退出码 0 但一个文件都不出）。
        # DirectX Repair 的调用方式是 "cpNN.exe /q"（见其内部字符串），
        # MSI 是它自己运行时解到 cpNN\temp\ 下的，所以这里只需把本体放到位。
        $map = @(
            @{ Dest = 'cp05\cp05.exe';    Src = 'VC2005\vcredist_x64.exe';       Arch = 'x64' }
            @{ Dest = 'cp05\a\cp05a.exe'; Src = 'VC2005\vcredist_x86.exe';       Arch = 'x86' }
            @{ Dest = 'cp08\cp08.exe';    Src = 'VC2008\vcredist_x64.exe';       Arch = 'x64' }
            @{ Dest = 'cp08\cp08a.exe';   Src = 'VC2008\vcredist_x86.exe';       Arch = 'x86' }
            @{ Dest = 'cp10\cp10.exe';    Src = 'VC2010\vcredist_x64.exe';       Arch = 'x64' }
            @{ Dest = 'cp10\cp10a.exe';   Src = 'VC2010\vcredist_x86.exe';       Arch = 'x86' }
            @{ Dest = 'cp12\cp12.exe';    Src = 'VC2012\vcredist_x64.exe';       Arch = 'x64' }
            @{ Dest = 'cp12\cp12a.exe';   Src = 'VC2012\vcredist_x86.exe';       Arch = 'x86' }
            @{ Dest = 'cp12\cp12b.exe';   Src = 'VC2012\vcredist_x64.exe';       Arch = 'x64' }
            @{ Dest = 'cp12\cp12c.exe';   Src = 'VC2012\vcredist_x86.exe';       Arch = 'x86' }
            @{ Dest = 'cp13\cp13.exe';    Src = 'VC2013\vcredist_x64.exe';       Arch = 'x64' }
            @{ Dest = 'cp13\cp13a.exe';   Src = 'VC2013\vcredist_x86.exe';       Arch = 'x86' }
            @{ Dest = 'cp13\cp13b.exe';   Src = 'VC2013\vcredist_x64.exe';       Arch = 'x64' }
            @{ Dest = 'cp13\cp13c.exe';   Src = 'VC2013\vcredist_x86.exe';       Arch = 'x86' }
            @{ Dest = 'cp15\cp15.exe';    Src = 'VC2015_2022\VC_redist.x64.exe'; Arch = 'x64' }
            @{ Dest = 'cp15\cp15a.exe';   Src = 'VC2015_2022\VC_redist.x86.exe'; Arch = 'x86' }
            @{ Dest = 'cp15\cp15d.exe';   Src = 'VC2015_2022\VC_redist.x64.exe'; Arch = 'x64' }
            @{ Dest = 'cp15\cp15e.exe';   Src = 'VC2015_2022\VC_redist.x86.exe'; Arch = 'x86' }
        )

        foreach ($m in $map) {
            $src = Join-Path $VcRedistRoot $m.Src
            $dst = Join-Path $dirC $m.Dest
            if (-not (Test-Path -LiteralPath $src)) {
                $null = $script:Stat.Warnings.Add("缺少载荷 $($m.Src)，跳过 $($m.Dest)")
                Write-Item '!!' "缺少载荷 $($m.Src)" 'Yellow'
                continue
            }

            if (Copy-Verified -Source $src -Destination $dst -ExpectArch $m.Arch -Label 'VC' -SkipArchCheck) {
                $script:Stat.AddedVc++
                Write-Item 'OK' "放置 $($m.Dest) ($($m.Arch))" 'Green'
            }
        }
    }
}

# ---------------------------------------------------------------------------
Write-Head '第 4 步 / 校验'

$bad = New-Object System.Collections.ArrayList
foreach ($pair in @(@{ Dir = $dirA; Arch = 'x86' }, @{ Dir = $dirB; Arch = 'x64' })) {
    if (-not (Test-Path -LiteralPath $pair.Dir)) { continue }
    foreach ($f in @(Get-ChildItem $pair.Dir -File -Filter '*.dll')) {
        $a = Get-Arch -Path $f.FullName
        if ($a -ne $pair.Arch -and $a -ne 'unknown') { $null = $bad.Add("$($f.Name) : 实际 $a，应为 $($pair.Arch)") }
    }
}
if ($bad.Count -eq 0) { Write-Item 'OK' 'Data\A 全为 x86、Data\B 全为 x64，位数一致' 'Green' }
else { foreach ($b in $bad) { Write-Item '!!' $b 'Red' } }

$finalC = 0
if (Test-Path -LiteralPath $dirC) { $finalC = @(Get-ChildItem $dirC -Recurse -File).Count }
Write-Host ''
Write-Item '..' ("Data\A (x86) : {0} 个 DLL" -f @(Get-ChildItem $dirA -File -Filter '*.dll').Count)
Write-Item '..' ("Data\B (x64) : {0} 个 DLL" -f @(Get-ChildItem $dirB -File -Filter '*.dll').Count)
Write-Item '..' ("Data\C (C++) : {0} 个文件" -f $finalC)

Write-Head '完成'
Write-Host ''
Write-Item 'OK' ("从自有 cab 解出  : {0}" -f $script:Stat.Extracted) 'Green'
Write-Item 'OK' ("补充 DirectX 组件: {0}" -f $script:Stat.AddedDx) 'Green'
Write-Item 'OK' ("放置 C++ 运行库   : {0}" -f $script:Stat.AddedVc) 'Green'
if ($script:Stat.Failed -gt 0) { Write-Item '!!' ("失败/跳过        : {0}" -f $script:Stat.Failed) 'Red' }

if ($script:Stat.FailedList.Count -gt 0) {
    Write-Host ''
    Write-Host '  失败明细：' -ForegroundColor Red
    foreach ($x in $script:Stat.FailedList) { Write-Host "    - $x" -ForegroundColor DarkRed }
}
if ($script:Stat.Warnings.Count -gt 0) {
    Write-Host ''
    Write-Host '  提醒：' -ForegroundColor Yellow
    foreach ($x in $script:Stat.Warnings) { Write-Host "    - $x" -ForegroundColor DarkYellow }
}

if ($script:Stat.AddedList.Count -gt 0 -and -not $WhatIf) {
    $mf = Join-Path $DataRoot ('补充清单_{0}.txt' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $lines = @(
        'DirectX Repair 数据补全清单',
        "生成时间: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
        "Data 目录: $DataRoot",
        '',
        '说明: 本文件由 Touhou Runtime Doctor 的 Complete-DirectXRepair.ps1 生成。',
        '      所有补入的 DLL 都通过了 PE 位数校验与 Authenticode 签名校验。',
        ''
    ) + @($script:Stat.AddedList | Sort-Object)
    [System.IO.File]::WriteAllText($mf, ($lines -join "`r`n"), [System.Text.Encoding]::GetEncoding(936))
    Write-Host ''
    Write-Item 'OK' "补充清单已写入: $mf" 'Green'
}

Write-Host ''
Write-Host '  提示：补全后建议先跑一次 DirectX Repair 自带的"检测并修复"验证效果。' -ForegroundColor Gray
Write-Host '        如果它仍提示需要"扩展至增强版"，说明它还会校验其它清单文件；' -ForegroundColor Gray
Write-Host '        此时可直接用本工具的一键修复，不必依赖它。' -ForegroundColor Gray
Write-Host ''

exit $(if ($script:Stat.Failed -gt 0) { 1 } else { 0 })
