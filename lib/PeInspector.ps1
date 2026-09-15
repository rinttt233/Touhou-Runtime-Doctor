# ============================================================================
#  PeInspector.ps1  --  纯 PowerShell 的 PE 文件解析器
#  用途：读取可执行文件的位数、静态导入表、以及二进制里出现的 DLL 名（覆盖
#        LoadLibrary 动态加载）。不依赖任何第三方库 / 不依赖 dumpbin。
#  这是整个体检引擎的地基：依赖清单来自这里，而不是硬编码的猜测。
# ============================================================================
Set-StrictMode -Version 2.0

# --- 常量 ---------------------------------------------------------------
$script:PE_MACHINE = @{
    0x014c = 'x86'
    0x8664 = 'x64'
    0x01c0 = 'ARM'
    0x01c4 = 'ARMv7'
    0xaa64 = 'ARM64'
    0x0200 = 'IA64'
    0x0000 = 'unknown'
}

# 这些前缀是 Windows 的 API 集（ApiSet），磁盘上没有真实文件，不算缺失。
$script:APISET_PREFIX = @('api-ms-win-', 'ext-ms-win-', 'api-ms-onecore')

function Get-PeInfo {
    <#
    .SYNOPSIS
        解析一个 PE 文件（exe/dll），返回位数、子系统、导入表与动态 DLL 字符串。
    .OUTPUTS
        PSCustomObject: Path, Ok, Error, Arch, Machine, Is64, Subsystem,
                        Imports[], DllStrings[], IsDotNet
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path
    )

    $result = [PSCustomObject]@{
        Path       = $Path
        Ok         = $false
        Error      = $null
        Arch       = 'unknown'
        Machine    = 0
        Is64       = $false
        IsDotNet   = $false
        Subsystem  = -1
        Imports    = @()
        DllStrings = @()
        SizeBytes  = 0
    }

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        $result.Error = '文件不存在'
        return $result
    }

    try {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
    } catch {
        $result.Error = "无法读取文件: $($_.Exception.Message)"
        return $result
    }

    $result.SizeBytes = $bytes.Length

    try {
        if ($bytes.Length -lt 0x40) { throw '文件太小，不是 PE 文件' }

        # --- DOS 头 -> e_lfanew ---
        $eLfanew = [System.BitConverter]::ToInt32($bytes, 0x3C)
        if ($eLfanew -le 0 -or ($eLfanew + 24) -ge $bytes.Length) { throw 'e_lfanew 越界' }

        $sig = [System.BitConverter]::ToUInt32($bytes, $eLfanew)
        if ($sig -ne 0x00004550) { throw '缺少 PE\0\0 签名（不是有效 PE 文件）' }

        # --- COFF 头 ---
        $machine     = [System.BitConverter]::ToUInt16($bytes, $eLfanew + 4)
        $numSections = [System.BitConverter]::ToUInt16($bytes, $eLfanew + 6)
        $sizeOptHdr  = [System.BitConverter]::ToUInt16($bytes, $eLfanew + 20)

        $result.Machine = $machine
        if ($script:PE_MACHINE.ContainsKey([int]$machine)) {
            $result.Arch = $script:PE_MACHINE[[int]$machine]
        }
        $result.Is64 = ($machine -eq 0x8664 -or $machine -eq 0xaa64 -or $machine -eq 0x0200)

        $optOff = $eLfanew + 24
        if (($optOff + 2) -ge $bytes.Length) { throw '可选头越界' }
        $magic = [System.BitConverter]::ToUInt16($bytes, $optOff)

        switch ($magic) {
            0x10b { $ddOff = $optOff + 96;  $peKind = 'PE32' }   # PE32
            0x20b { $ddOff = $optOff + 112; $peKind = 'PE32+' }  # PE32+
            default { throw ("未知的可选头 magic: 0x{0:X}" -f $magic) }
        }

        # 子系统在可选头 +68（PE32 / PE32+ 同偏移）
        $result.Subsystem = [System.BitConverter]::ToUInt16($bytes, $optOff + 68)

        # --- 节表 ---
        $secOff = $optOff + $sizeOptHdr
        $sections = New-Object System.Collections.ArrayList
        for ($i = 0; $i -lt $numSections; $i++) {
            $so = $secOff + ($i * 40)
            if (($so + 40) -gt $bytes.Length) { break }
            $null = $sections.Add([PSCustomObject]@{
                Name     = [System.Text.Encoding]::ASCII.GetString($bytes, $so, 8).TrimEnd([char]0)
                VirtualSize     = [System.BitConverter]::ToUInt32($bytes, $so + 8)
                VirtualAddress  = [System.BitConverter]::ToUInt32($bytes, $so + 12)
                SizeOfRawData   = [System.BitConverter]::ToUInt32($bytes, $so + 16)
                PointerToRawData= [System.BitConverter]::ToUInt32($bytes, $so + 20)
            })
        }

        # RVA -> 文件偏移
        $rvaToOffset = {
            param([uint32]$rva)
            foreach ($s in $sections) {
                $span = [Math]::Max($s.VirtualSize, $s.SizeOfRawData)
                if ($rva -ge $s.VirtualAddress -and $rva -lt ($s.VirtualAddress + $span)) {
                    $off = $rva - $s.VirtualAddress + $s.PointerToRawData
                    if ($off -lt $bytes.Length) { return [int]$off }
                    return -1
                }
            }
            return -1
        }

        # 读取以 0 结尾的 ASCII 字符串
        $readCString = {
            param([int]$off, [int]$max = 260)
            if ($off -lt 0 -or $off -ge $bytes.Length) { return $null }
            $end = $off
            $limit = [Math]::Min($off + $max, $bytes.Length)
            while ($end -lt $limit -and $bytes[$end] -ne 0) { $end++ }
            if ($end -le $off) { return $null }
            return [System.Text.Encoding]::ASCII.GetString($bytes, $off, $end - $off)
        }

        # --- 数据目录：索引 1 = 导入表，索引 14 = CLR(.NET) ---
        if (($ddOff + 16 * 8) -lt $bytes.Length) {
            $importRva = [System.BitConverter]::ToInt32($bytes, $ddOff + 8)
            $clrRva    = [System.BitConverter]::ToInt32($bytes, $ddOff + 14 * 8)
            if ($clrRva -ne 0) { $result.IsDotNet = $true }

            $imports = New-Object System.Collections.ArrayList
            if ($importRva -gt 0) {
                $descOff = & $rvaToOffset ([uint32]$importRva)
                if ($descOff -ge 0) {
                    for ($n = 0; $n -lt 4096; $n++) {
                        $do = $descOff + ($n * 20)
                        if (($do + 20) -gt $bytes.Length) { break }
                        $nameRva = [System.BitConverter]::ToInt32($bytes, $do + 12)
                        $firstThunk = [System.BitConverter]::ToInt32($bytes, $do + 16)
                        if ($nameRva -eq 0 -and $firstThunk -eq 0) { break }
                        if ($nameRva -eq 0) { continue }
                        $no = & $rvaToOffset ([uint32]$nameRva)
                        $dllName = & $readCString $no
                        if ($dllName) { $null = $imports.Add($dllName) }
                    }
                }
            }
            $result.Imports = @($imports | Sort-Object -Unique)
        }

        # --- 二进制里的 DLL 名字符串（动态 LoadLibrary 兜底）---
        $result.DllStrings = Get-PeDllStrings -Bytes $bytes

        $result.Ok = $true
    } catch {
        $result.Error = $_.Exception.Message
    }

    return $result
}

function Get-PeDllStrings {
    <#
    .SYNOPSIS
        从二进制中提取形如 xxx.dll 的字符串（同时覆盖 ASCII 与 UTF-16LE）。
    #>
    param(
        [Parameter(Mandatory = $true)][byte[]]$Bytes,
        [int]$MinNameLength = 4
    )

    $found = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

    # 用 Latin-1 解码可以保证字节与字符 1:1 对应，正则匹配不会错位。
    $latin1 = [System.Text.Encoding]::GetEncoding(28591)
    $pattern = '[A-Za-z0-9_\-\.]{' + $MinNameLength + ',80}\.dll'

    $full = $latin1.GetString($Bytes)
    foreach ($m in [regex]::Matches($full, $pattern, 'IgnoreCase')) {
        $null = $found.Add($m.Value)
    }

    # UTF-16LE：偶数位与奇数位拆开各自解码即可还原宽字符 ASCII 串
    $half = [int][Math]::Floor($Bytes.Length / 2)
    if ($half -gt 0) {
        $even = New-Object byte[] $half
        $odd  = New-Object byte[] $half
        for ($i = 0; $i -lt $half; $i++) {
            $even[$i] = $Bytes[$i * 2]
            $odd[$i]  = $Bytes[$i * 2 + 1]
        }
        foreach ($buf in @($even, $odd)) {
            $s = $latin1.GetString($buf)
            foreach ($m in [regex]::Matches($s, $pattern, 'IgnoreCase')) {
                $null = $found.Add($m.Value)
            }
        }
    }

    # 过滤掉明显的噪声：路径分隔符残留、过长、以点开头
    $clean = @($found | Where-Object {
        $_ -notmatch '^\.' -and
        $_ -notmatch '\.\.' -and
        ($_ -split '\.').Count -ge 2 -and
        $_.Length -le 64
    })

    return @($clean | Sort-Object)
}

function Test-IsApiSet {
    <#
    .SYNOPSIS
        判断是否 Windows API 集虚拟 DLL（磁盘上无实体文件，不应判为缺失）。
    #>
    param([Parameter(Mandatory = $true)][string]$Name)
    foreach ($p in $script:APISET_PREFIX) {
        if ($Name.StartsWith($p, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Resolve-DependencyPath {
    <#
    .SYNOPSIS
        按 Windows 加载器的搜索顺序为一个导入项找落地文件。
    .DESCRIPTION
        顺序：exe 所在目录 -> 应用目录 -> 系统目录 -> System -> PATH。
        关键点：系统目录必须按【目标进程位数】来选，而不是按当前脚本进程：
          64 位系统：32 位程序加载 SysWOW64，64 位程序加载 System32
          32 位系统：32 位程序加载 System32（没有 WOW64 层），x64 不适用
        统一走 Get-TrdSystemDir，避免在别处硬编码目录名而"补错位数"。
    .PARAMETER Bitness
        'x86' 或 'x64'，表示发起加载的进程位数。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Bitness,
        [string[]]$ExtraDirs = @(),
        [string[]]$ExcludeDirs = @()
    )

    $candidates = New-Object System.Collections.ArrayList

    # 位数 -> 系统目录的映射统一由 Get-TrdSystemDir 决定。
    # 在这里硬编码 SysWOW64 是错的：32 位 Windows 没有 WOW64 层，
    # 32 位 DLL 就住在 System32 里。
    $dirX86 = Get-TrdSystemDir -Bitness 'x86'
    $dirX64 = Get-TrdSystemDir -Bitness 'x64'
    $sysDir = if ($env:SystemRoot) { Join-Path $env:SystemRoot 'System' } else { $null }

    $order = New-Object System.Collections.ArrayList
    foreach ($d in $ExtraDirs) { if ($d) { $null = $order.Add($d) } }
    if ($Bitness -eq 'x86') {
        if ($dirX86) { $null = $order.Add($dirX86) }   # 64 位系统=SysWOW64，32 位系统=System32
        if ($dirX64 -and $dirX64 -ne $dirX86) { $null = $order.Add($dirX64) }
    } else {
        if ($dirX64) { $null = $order.Add($dirX64) }
        if ($dirX86 -and $dirX86 -ne $dirX64) { $null = $order.Add($dirX86) }
    }
    if ($sysDir) { $null = $order.Add($sysDir) }

    $pathDirs = @()
    if ($env:PATH) { $pathDirs = $env:PATH -split ';' | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Container) } }
    foreach ($d in $pathDirs) { $null = $order.Add($d) }

    foreach ($dir in $order) {
        if ($ExcludeDirs -contains $dir) { continue }
        try {
            $full = Join-Path $dir $Name
            if (Test-Path -LiteralPath $full -PathType Leaf) {
                return [PSCustomObject]@{ Found = $true; FullPath = $full; SearchDir = $dir }
            }
        } catch { }
    }

    return [PSCustomObject]@{ Found = $false; FullPath = $null; SearchDir = $null }
}

function Get-PeFileVersionString {
    <#
    .SYNOPSIS
        安全地取文件版本号字符串（部分汉化 exe 无版本资源，需容错）。
    #>
    param([Parameter(Mandatory = $true)][string]$Path)
    try {
        $vi = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($Path)
        if ($vi.FileVersion) { return $vi.FileVersion }
        if ($vi.ProductVersion) { return $vi.ProductVersion }
        return $null
    } catch {
        return $null
    }
}
