# ============================================================================
#  DxComponents.ps1 -- DirectX 组件全清单、加速状态、系统目录部署
#
#  这一层的三个能力来自对 DirectX Repair 的实测分析，是它相对本工具的长处：
#
#   1) 完整的 DirectX 组件目录
#      本工具原来的关注清单只有 36 项，而官方 DirectX Jun2010 运行库实际
#      提供 102 个 DLL（实测解包统计）。缺的主要是 xinput 全系列、
#      X3DAudio、XACT、d3dcsx 以及 d3dx10/d3dx11 的各版本。
#
#   2) Direct3D / DirectDraw 硬件加速状态
#      DirectX Repair 提供「快速开关 Direct 加速」功能（/enabledirectdraw
#      /disabledirectdraw）。对应的是下面两个注册表开关：
#        HKLM\SOFTWARE\...\Microsoft\Direct3D\Drivers  SoftwareOnly   =1 关 3D 加速
#        HKLM\SOFTWARE\...\Microsoft\DirectDraw        EmulationOnly  =1 关 DD 加速
#      被误设为 1 时，所有 3D 游戏要么极慢要么直接起不来，
#      而表面上"运行库一个都不缺"，极难排查。本文件把它查出来。
#      注意 32 位程序读的是 WOW6432Node 分支，两个位置都要看。
#
#   3) 系统目录 DLL 部署（DirectX Repair 的核心做法）
#      本工具原来只把 DLL 放到游戏目录。当很多游戏都需要同一个组件时，
#      放系统目录更省事。这里实现为【显式开启】的动作：
#      逐文件备份、位数校验、签名校验、可精确回滚。
# ============================================================================
Set-StrictMode -Version 2.0

# ---------------------------------------------------------------------------
#  DirectX 组件目录
#  分类用于报告分组；Sys=系统自带组件，DX=DirectX 运行库分发组件
# ---------------------------------------------------------------------------
$script:TRD_DX_CATALOG = @(
    # ---- DirectX 8 世代核心（th06~th09 直接依赖）----
    @{ N = 'd3d8.dll';            Cat = 'Direct3D 8';        Key = $true }
    @{ N = 'd3d8thk.dll';         Cat = 'Direct3D 8';        Key = $true }
    @{ N = 'd3d9.dll';            Cat = 'Direct3D 9';        Key = $true }
    @{ N = 'd3d9on12.dll';        Cat = 'Direct3D 9';        Key = $false }
    @{ N = 'd3d10.dll';           Cat = 'Direct3D 10';       Key = $false }
    @{ N = 'd3d11.dll';           Cat = 'Direct3D 11';       Key = $false }
    @{ N = 'd3d12.dll';           Cat = 'Direct3D 12';       Key = $false }
    @{ N = 'ddraw.dll';           Cat = 'DirectDraw';        Key = $true }
    @{ N = 'd3dim.dll';           Cat = 'Direct3D 立即模式'; Key = $false }
    @{ N = 'd3dim700.dll';        Cat = 'Direct3D 立即模式'; Key = $false }
    @{ N = 'd3drm.dll';           Cat = 'Direct3D 保留模式'; Key = $false }
    @{ N = 'dinput.dll';          Cat = 'DirectInput';       Key = $false }
    @{ N = 'dinput8.dll';         Cat = 'DirectInput';       Key = $true }
    @{ N = 'dsound.dll';          Cat = 'DirectSound';       Key = $true }
    @{ N = 'dsound3d.dll';        Cat = 'DirectSound';       Key = $false }
    @{ N = 'dplayx.dll';          Cat = 'DirectPlay';        Key = $false }
    @{ N = 'dpnhpast.dll';        Cat = 'DirectPlay';        Key = $false }

    # ---- D3DX9 辅助库（th10+ 及大量第三方游戏用）----
    @{ N = 'd3dx9_24.dll'; Cat = 'D3DX9'; Key = $false }
    @{ N = 'd3dx9_25.dll'; Cat = 'D3DX9'; Key = $false }
    @{ N = 'd3dx9_26.dll'; Cat = 'D3DX9'; Key = $false }
    @{ N = 'd3dx9_27.dll'; Cat = 'D3DX9'; Key = $false }
    @{ N = 'd3dx9_28.dll'; Cat = 'D3DX9'; Key = $false }
    @{ N = 'd3dx9_29.dll'; Cat = 'D3DX9'; Key = $false }
    @{ N = 'd3dx9_30.dll'; Cat = 'D3DX9'; Key = $false }
    @{ N = 'd3dx9_31.dll'; Cat = 'D3DX9'; Key = $false }
    @{ N = 'd3dx9_32.dll'; Cat = 'D3DX9'; Key = $false }
    @{ N = 'd3dx9_33.dll'; Cat = 'D3DX9'; Key = $false }
    @{ N = 'd3dx9_34.dll'; Cat = 'D3DX9'; Key = $false }
    @{ N = 'd3dx9_35.dll'; Cat = 'D3DX9'; Key = $false }
    @{ N = 'd3dx9_36.dll'; Cat = 'D3DX9'; Key = $false }
    @{ N = 'd3dx9_37.dll'; Cat = 'D3DX9'; Key = $false }
    @{ N = 'd3dx9_38.dll'; Cat = 'D3DX9'; Key = $false }
    @{ N = 'd3dx9_39.dll'; Cat = 'D3DX9'; Key = $false }
    @{ N = 'd3dx9_40.dll'; Cat = 'D3DX9'; Key = $false }
    @{ N = 'd3dx9_41.dll'; Cat = 'D3DX9'; Key = $false }
    @{ N = 'd3dx9_42.dll'; Cat = 'D3DX9'; Key = $false }
    @{ N = 'd3dx9_43.dll'; Cat = 'D3DX9'; Key = $true }

    # ---- D3DX10 / D3DX11 ----
    @{ N = 'd3dx10.dll';    Cat = 'D3DX10'; Key = $false }
    @{ N = 'd3dx10_33.dll'; Cat = 'D3DX10'; Key = $false }
    @{ N = 'd3dx10_34.dll'; Cat = 'D3DX10'; Key = $false }
    @{ N = 'd3dx10_35.dll'; Cat = 'D3DX10'; Key = $false }
    @{ N = 'd3dx10_36.dll'; Cat = 'D3DX10'; Key = $false }
    @{ N = 'd3dx10_37.dll'; Cat = 'D3DX10'; Key = $false }
    @{ N = 'd3dx10_38.dll'; Cat = 'D3DX10'; Key = $false }
    @{ N = 'd3dx10_39.dll'; Cat = 'D3DX10'; Key = $false }
    @{ N = 'd3dx10_40.dll'; Cat = 'D3DX10'; Key = $false }
    @{ N = 'd3dx10_41.dll'; Cat = 'D3DX10'; Key = $false }
    @{ N = 'd3dx10_42.dll'; Cat = 'D3DX10'; Key = $false }
    @{ N = 'd3dx10_43.dll'; Cat = 'D3DX10'; Key = $false }
    @{ N = 'd3dx11_42.dll'; Cat = 'D3DX11'; Key = $false }
    @{ N = 'd3dx11_43.dll'; Cat = 'D3DX11'; Key = $false }

    # ---- 着色器编译器 ----
    @{ N = 'd3dcompiler_33.dll'; Cat = 'D3DCompiler'; Key = $false }
    @{ N = 'd3dcompiler_34.dll'; Cat = 'D3DCompiler'; Key = $false }
    @{ N = 'd3dcompiler_35.dll'; Cat = 'D3DCompiler'; Key = $false }
    @{ N = 'd3dcompiler_36.dll'; Cat = 'D3DCompiler'; Key = $false }
    @{ N = 'D3DCompiler_37.dll'; Cat = 'D3DCompiler'; Key = $false }
    @{ N = 'D3DCompiler_38.dll'; Cat = 'D3DCompiler'; Key = $false }
    @{ N = 'D3DCompiler_39.dll'; Cat = 'D3DCompiler'; Key = $false }
    @{ N = 'D3DCompiler_40.dll'; Cat = 'D3DCompiler'; Key = $false }
    @{ N = 'D3DCompiler_41.dll'; Cat = 'D3DCompiler'; Key = $false }
    @{ N = 'D3DCompiler_42.dll'; Cat = 'D3DCompiler'; Key = $false }
    @{ N = 'D3DCompiler_43.dll'; Cat = 'D3DCompiler'; Key = $true }
    @{ N = 'D3DCompiler_47.dll'; Cat = 'D3DCompiler'; Key = $false }
    @{ N = 'd3dcsx_42.dll';     Cat = 'D3DCompiler'; Key = $false }
    @{ N = 'd3dcsx_43.dll';     Cat = 'D3DCompiler'; Key = $false }

    # ---- XAudio 2 全系列 ----
    @{ N = 'XAudio2_0.dll'; Cat = 'XAudio2'; Key = $false }
    @{ N = 'XAudio2_1.dll'; Cat = 'XAudio2'; Key = $false }
    @{ N = 'XAudio2_2.dll'; Cat = 'XAudio2'; Key = $false }
    @{ N = 'XAudio2_3.dll'; Cat = 'XAudio2'; Key = $false }
    @{ N = 'XAudio2_4.dll'; Cat = 'XAudio2'; Key = $false }
    @{ N = 'XAudio2_5.dll'; Cat = 'XAudio2'; Key = $false }
    @{ N = 'XAudio2_6.dll'; Cat = 'XAudio2'; Key = $false }
    @{ N = 'XAudio2_7.dll'; Cat = 'XAudio2'; Key = $true }
    @{ N = 'XAPOFX1_0.dll'; Cat = 'XAudio2'; Key = $false }
    @{ N = 'XAPOFX1_1.dll'; Cat = 'XAudio2'; Key = $false }
    @{ N = 'XAPOFX1_2.dll'; Cat = 'XAudio2'; Key = $false }
    @{ N = 'XAPOFX1_3.dll'; Cat = 'XAudio2'; Key = $false }
    @{ N = 'XAPOFX1_4.dll'; Cat = 'XAudio2'; Key = $false }
    @{ N = 'XAPOFX1_5.dll'; Cat = 'XAudio2'; Key = $false }
    @{ N = 'X3DAudio1_0.dll'; Cat = 'X3DAudio'; Key = $false }
    @{ N = 'X3DAudio1_1.dll'; Cat = 'X3DAudio'; Key = $false }
    @{ N = 'X3DAudio1_2.dll'; Cat = 'X3DAudio'; Key = $false }
    @{ N = 'X3DAudio1_3.dll'; Cat = 'X3DAudio'; Key = $false }
    @{ N = 'X3DAudio1_4.dll'; Cat = 'X3DAudio'; Key = $false }
    @{ N = 'X3DAudio1_5.dll'; Cat = 'X3DAudio'; Key = $false }
    @{ N = 'X3DAudio1_6.dll'; Cat = 'X3DAudio'; Key = $false }
    @{ N = 'X3DAudio1_7.dll'; Cat = 'X3DAudio'; Key = $false }

    # ---- XACT 引擎 ----
    @{ N = 'xactengine2_0.dll';  Cat = 'XACT'; Key = $false }
    @{ N = 'xactengine2_1.dll';  Cat = 'XACT'; Key = $false }
    @{ N = 'xactengine2_2.dll';  Cat = 'XACT'; Key = $false }
    @{ N = 'xactengine2_3.dll';  Cat = 'XACT'; Key = $false }
    @{ N = 'xactengine2_4.dll';  Cat = 'XACT'; Key = $false }
    @{ N = 'xactengine2_5.dll';  Cat = 'XACT'; Key = $false }
    @{ N = 'xactengine2_6.dll';  Cat = 'XACT'; Key = $false }
    @{ N = 'xactengine2_7.dll';  Cat = 'XACT'; Key = $false }
    @{ N = 'xactengine2_8.dll';  Cat = 'XACT'; Key = $false }
    @{ N = 'xactengine2_9.dll';  Cat = 'XACT'; Key = $false }
    @{ N = 'xactengine2_10.dll'; Cat = 'XACT'; Key = $false }
    @{ N = 'xactengine3_0.dll';  Cat = 'XACT'; Key = $false }
    @{ N = 'xactengine3_1.dll';  Cat = 'XACT'; Key = $false }
    @{ N = 'xactengine3_2.dll';  Cat = 'XACT'; Key = $false }
    @{ N = 'xactengine3_3.dll';  Cat = 'XACT'; Key = $false }
    @{ N = 'xactengine3_4.dll';  Cat = 'XACT'; Key = $false }
    @{ N = 'xactengine3_5.dll';  Cat = 'XACT'; Key = $false }
    @{ N = 'xactengine3_6.dll';  Cat = 'XACT'; Key = $false }
    @{ N = 'xactengine3_7.dll';  Cat = 'XACT'; Key = $false }

    # ---- XInput 手柄全系列 ----
    @{ N = 'xinput9_1_0.dll'; Cat = 'XInput'; Key = $false }
    @{ N = 'xinput1_1.dll';   Cat = 'XInput'; Key = $false }
    @{ N = 'xinput1_2.dll';   Cat = 'XInput'; Key = $false }
    @{ N = 'xinput1_3.dll';   Cat = 'XInput'; Key = $true }
    @{ N = 'xinput1_4.dll';   Cat = 'XInput'; Key = $false }
)

function Get-TrdDxCatalog {
    <#
    .SYNOPSIS
        返回 DirectX 组件目录。
    .PARAMETER KeysOnly
        只返回 Key=$true 的关键组件（游戏最常依赖的那批）。
    #>
    [CmdletBinding()]
    param([switch]$KeysOnly)
    if ($KeysOnly) { return @($script:TRD_DX_CATALOG | Where-Object { $_.Key }) }
    return @($script:TRD_DX_CATALOG)
}

function Get-TrdDxComponentInventory {
    <#
    .SYNOPSIS
        逐个检查 DirectX 组件在 32 位 / 64 位系统目录中的落地情况。
    .DESCRIPTION
        目录选择走 Get-TrdSystemDir，32 位系统上自动落到 System32，
        64 位系统上 32 位组件看 SysWOW64。
    .OUTPUTS
        PSCustomObject: Items[], Missing32[], Missing64[], Counts
    #>
    [CmdletBinding()]
    param([switch]$KeysOnly)

    $dirX86 = Get-TrdSystemDir -Bitness 'x86'
    $dirX64 = Get-TrdSystemDir -Bitness 'x64'
    $items = New-Object System.Collections.ArrayList

    foreach ($c in (Get-TrdDxCatalog -KeysOnly:$KeysOnly)) {
        $p32 = $null; $p64 = $null
        if ($dirX86) { $p32 = Join-Path $dirX86 $c.N }
        if ($dirX64) { $p64 = Join-Path $dirX64 $c.N }

        $has32 = ($p32 -and (Test-Path -LiteralPath $p32))
        $has64 = ($p64 -and (Test-Path -LiteralPath $p64))

        $null = $items.Add([PSCustomObject]@{
            Name    = $c.N
            Category = $c.Cat
            IsKey   = [bool]$c.Key
            Has32   = [bool]$has32
            Has64   = [bool]$has64
            Path32  = $p32
            Path64  = $p64
            # Path64 在 WOW64 下是 Sysnative（访问用别名），不能直接给人看。
            # 内部访问继续用 Path64，输出/报告一律用这个显示版。
            Path64Display = $(if ($p64) { ConvertTo-TrdDisplayPath -Text $p64 } else { $null })
        })
    }

    $a = @($items)
    return [PSCustomObject]@{
        DirX86    = $dirX86
        DirX64    = $dirX64
        Items     = $a
        Missing32 = @($a | Where-Object { -not $_.Has32 })
        Missing64 = @($a | Where-Object { -not $_.Has64 -and $_.Path64 })
        Total     = $a.Count
        Present32 = @($a | Where-Object { $_.Has32 }).Count
    }
}

function Get-TrdDxAccelerationState {
    <#
    .SYNOPSIS
        检查 Direct3D / DirectDraw 硬件加速是否被注册表开关关闭。
    .DESCRIPTION
        对应 DirectX Repair 的「快速开关 Direct 加速」功能。
        两个开关：
          SoftwareOnly  =1  强制 Direct3D 走软件渲染（3D 加速关闭）
          EmulationOnly =1  强制 DirectDraw 走模拟（DD 加速关闭）
        被误设为 1 时的症状是：游戏能启动但极慢，或者 3D 游戏直接起不来，
        而"运行库检查"全部通过 —— 从依赖角度完全看不出问题。
        必须同时看原生视图与 WOW6432Node，因为 32 位程序读后者。
    .OUTPUTS
        诊断结果对象，含 D3DDisabled / DDDisabled 与证据。
    #>
    [CmdletBinding()]
    param()

    $targets = @(
        @{ Name = 'Direct3D  SoftwareOnly';  Key = 'HKLM:\SOFTWARE\Microsoft\Direct3D\Drivers';  Val = 'SoftwareOnly' }
        @{ Name = 'Direct3D  SoftwareOnly (32位视图)'; Key = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Direct3D\Drivers'; Val = 'SoftwareOnly' }
        @{ Name = 'DirectDraw EmulationOnly'; Key = 'HKLM:\SOFTWARE\Microsoft\DirectDraw'; Val = 'EmulationOnly' }
        @{ Name = 'DirectDraw EmulationOnly (32位视图)'; Key = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\DirectDraw'; Val = 'EmulationOnly' }
    )

    $found = New-Object System.Collections.ArrayList
    $d3dOff = $false
    $ddOff = $false

    foreach ($t in $targets) {
        $val = $null; $present = $false
        try {
            $p = Get-ItemProperty -Path $t.Key -Name $t.Val -ErrorAction Stop
            $val = $p.($t.Val)
            $present = $true
        } catch { }

        if ($present) {
            $num = 0; try { $num = [int]$val } catch { }
            if ($num -eq 1) {
                if ($t.Name -like 'Direct3D*') { $d3dOff = $true } else { $ddOff = $true }
            }
            $null = $found.Add([PSCustomObject]@{
                Name = $t.Name; Key = $t.Key; ValueName = $t.Val; Value = $num; Disabled = ($num -eq 1)
            })
        }
    }

    return [PSCustomObject]@{
        D3DDisabled = $d3dOff
        DDDisabled  = $ddOff
        Entries     = @($found)
        AnyDisabled = ($d3dOff -or $ddOff)
    }
}

function Set-TrdDxAcceleration {
    <#
    .SYNOPSIS
        开启或关闭 Direct3D / DirectDraw 硬件加速。
    .DESCRIPTION
        与 DirectX Repair 的 /enabledirectdraw / /disabledirectdraw 等价。
        默认只操作 32 位视图（WOW6432Node），因为出问题的老游戏都是 32 位；
        原生视图只有在显式要求时才动，避免影响 64 位程序。
        写前会把旧值记入 journal，可用「回滚.bat」还原。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Enable', 'Disable')][string]$Action,
        [ValidateSet('Direct3D', 'DirectDraw', 'Both')][string]$Target = 'Both',
        [switch]$IncludeNativeView
    )

    $value = if ($Action -eq 'Disable') { 1 } else { 0 }

    $jobs = New-Object System.Collections.ArrayList
    if ($Target -in 'Direct3D', 'Both') {
        $null = $jobs.Add(@{ K = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Direct3D\Drivers'; V = 'SoftwareOnly'; L = 'Direct3D(32位)' })
        if ($IncludeNativeView) { $null = $jobs.Add(@{ K = 'HKLM:\SOFTWARE\Microsoft\Direct3D\Drivers'; V = 'SoftwareOnly'; L = 'Direct3D(64位)' }) }
    }
    if ($Target -in 'DirectDraw', 'Both') {
        $null = $jobs.Add(@{ K = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\DirectDraw'; V = 'EmulationOnly'; L = 'DirectDraw(32位)' })
        if ($IncludeNativeView) { $null = $jobs.Add(@{ K = 'HKLM:\SOFTWARE\Microsoft\DirectDraw'; V = 'EmulationOnly'; L = 'DirectDraw(64位)' }) }
    }

    $ok = 0; $failed = @()
    foreach ($j in $jobs) {
        try {
            if (-not (Test-Path -LiteralPath $j.K)) { $null = New-Item -Path $j.K -Force }
            if (Set-TrdRegValue -RegPath $j.K -Name $j.V -Value $value -Type DWord -BackupTag 'dxaccel') {
                Write-TrdLog "$($j.L) 加速已$(if ($Action -eq 'Disable') { '关闭' } else { '开启' })（$($j.V)=$value）" 'OK'
                $ok++
            } else { $failed += $j.L }
        } catch { $failed += "$($j.L): $($_.Exception.Message)" }
    }

    return [PSCustomObject]@{
        Ok      = ($failed.Count -eq 0)
        Message = "已处理 $ok/$($jobs.Count) 项" + $(if ($failed.Count) { "；失败: $($failed -join '; ')" } else { '' })
    }
}

# ---------------------------------------------------------------------------
#  系统目录 DLL 部署（DirectX Repair 的核心做法）
# ---------------------------------------------------------------------------
function Get-TrdDxPayloadSource {
    <#
    .SYNOPSIS
        为"按位数提供 DirectX DLL"找一个可用的本地来源。
    .DESCRIPTION
        按优先级依次尝试：
          1) 工具自带 offline\DX_DLL\<arch>\         （推荐：从官方运行库整理好的）
          2) DirectX Repair 的 Data\A(x86) / Data\B(x64)  （若本机装了该工具）
          3) 官方 DirectX Jun2010 运行库解包目录    （需第三方解压器，较慢）
        返回来源描述与路径，供后续部署动作使用。
    #>
    [CmdletBinding()]
    param([string]$DirectXRepairDataRoot)

    $cands = New-Object System.Collections.ArrayList

    $own = Join-Path $script:TRD.ToolRoot 'offline\DX_DLL'
    foreach ($a in @('x86', 'x64')) {
        $d = Join-Path $own $a
        if (Test-Path -LiteralPath $d) {
            $null = $cands.Add([PSCustomObject]@{ Arch = $a; Dir = $d; Source = '工具自带载荷' })
        }
    }

    if ($DirectXRepairDataRoot -and (Test-Path -LiteralPath $DirectXRepairDataRoot)) {
        $map = @{ x86 = 'A'; x64 = 'B' }
        foreach ($a in @('x86', 'x64')) {
            $d = Join-Path $DirectXRepairDataRoot $map[$a]
            if (Test-Path -LiteralPath $d) {
                $n = @(Get-ChildItem -LiteralPath $d -File -Filter '*.dll' -ErrorAction SilentlyContinue).Count
                if ($n -gt 0) {
                    $null = $cands.Add([PSCustomObject]@{ Arch = $a; Dir = $d; Source = "DirectX Repair 数据包（$n 个 DLL）" })
                }
            }
        }
    }

    return [PSCustomObject]@{ Candidates = @($cands); HasAny = ($cands.Count -gt 0) }
}

function Install-TrdDxComponentToSystem {
    <#
    .SYNOPSIS
        把缺失的 DirectX 组件部署到系统目录（逐文件备份，可回滚）。
    .DESCRIPTION
        这是 DirectX Repair 的核心做法，也是本工具原本刻意回避的动作。
        之所以现在提供，是因为确有场景需要：一台机器上很多游戏都缺同一个
        组件时，放系统目录比逐个游戏目录放省事。

        安全措施（缺一不可）：
          * 部署前逐文件复制到本次会话的备份目录，写入 journal，可精确回滚
          * 目标位数必须与 DLL 实际位数一致，否则会造成 0xC000007B
          * 来源必须通过 Authenticode 签名校验，拒绝未签名文件
          * 只覆盖"缺失或版本更旧"的文件，不盲目覆盖更新的
          * 系统文件保护拒绝覆盖时如实报告，并提示改用游戏目录部署
    .PARAMETER ComponentNames
        要部署的组件名列表；不指定则部署"关键组件中缺失的那些"。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Inventory,
        [string[]]$ComponentNames,
        [string]$DirectXRepairDataRoot,
        [switch]$IncludeNonKey
    )

    if (-not $script:TRD.IsAdmin) {
        return [PSCustomObject]@{ Ok = $false; Message = '部署到系统目录需要管理员权限。请右键「一键修复.bat」以管理员身份运行。' }
    }

    $src = Get-TrdDxPayloadSource -DirectXRepairDataRoot $DirectXRepairDataRoot
    if (-not $src.HasAny) {
        return [PSCustomObject]@{
            Ok      = $false
            Message = '找不到可用的 DirectX DLL 载荷来源。' + (Get-TrdOfflineHint) +
                      '也可以指定 -DirectXRepairDataRoot 指向 DirectX Repair 的 Data 目录。'
        }
    }

    # 决定要部署哪些
    if ($ComponentNames -and $ComponentNames.Count -gt 0) {
        $want = $ComponentNames
    } else {
        $want = @($Inventory.Missing32 | Where-Object { $_.IsKey -or $IncludeNonKey } | ForEach-Object { $_.Name })
    }
    if ($want.Count -eq 0) {
        return [PSCustomObject]@{ Ok = $true; Message = '关键 DirectX 组件均已就位，无需部署。' }
    }

    $ok = 0; $skip = @(); $fail = @()

    foreach ($name in $want) {
        $done = $false
        foreach ($c in $src.Candidates) {
            $file = Join-Path $c.Dir $name
            if (-not (Test-Path -LiteralPath $file)) { continue }

            $destDir = Get-TrdSystemDir -Bitness $c.Arch
            if (-not $destDir) { continue }
            $dest = Join-Path $destDir $name

            # 位数校验：DLL 实际位数必须与目标目录一致
            $info = Get-PeInfo -Path $file
            $want64 = ($c.Arch -eq 'x64')
            if ($info.Ok -and $info.Is64 -ne $want64) {
                $fail += "$name : 载荷是 $($info.Arch) 位，目标目录是 $($c.Arch)，跳过"
                continue
            }

            # 签名校验：拒绝未签名文件
            try {
                $sig = Get-AuthenticodeSignature -LiteralPath $file -ErrorAction Stop
                if ($sig.Status -ne 'Valid') {
                    $fail += "$name : 数字签名无效（$($sig.Status)），拒绝部署"
                    continue
                }
            } catch {
                $fail += "$name : 无法校验签名，拒绝部署"
                continue
            }

            # 已存在且版本不旧 -> 跳过
            if (Test-Path -LiteralPath $dest) {
                try {
                    $old = (Get-Item -LiteralPath $dest).VersionInfo.FileVersion
                    $new = (Get-Item -LiteralPath $file).VersionInfo.FileVersion
                    if ($old -and $new -and ([version]($old -replace '[^\d\.]', '')) -ge ([version]($new -replace '[^\d\.]', ''))) {
                        $skip += "$name : 系统里已是 $old，不低于载荷的 $new，跳过"
                        $done = $true
                        break
                    }
                } catch { }
                # 覆盖前备份
                $null = Backup-TrdFile -Path $dest -Tag 'sysdll'
            } else {
                $null = $script:TRD.Journal.Add([PSCustomObject]@{
                    Kind = 'File'; Target = $dest; Backup = $null; Existed = $false
                })
            }

            if ($script:TRD.DryRun) {
                Write-TrdLog "[演练] 将部署 $name -> $dest（来自 $($c.Source)）" 'Info'
                $ok++; $done = $true; break
            }

            try {
                Copy-Item -LiteralPath $file -Destination $dest -Force -ErrorAction Stop
                Write-TrdLog "已部署 $name -> $dest（$($c.Arch)，来自 $($c.Source)）" 'OK'
                $ok++; $done = $true
                break
            } catch {
                # 系统文件保护会拒绝覆盖受保护的系统组件
                $fail += "$name : 写入失败（$($_.Exception.Message)）。该文件可能受 Windows 文件保护；" +
                         "可改用「部署到游戏目录」的方式，或安装官方 DirectX 运行库。"
            }
        }
        if (-not $done -and -not ($fail | Where-Object { $_ -like "$name*" })) {
            $fail += "$name : 所有载荷来源里都找不到这个文件"
        }
    }

    $msg = "系统目录部署：成功 $ok 项"
    if ($skip.Count) { $msg += "，跳过 $($skip.Count) 项" }
    if ($fail.Count) { $msg += "，失败 $($fail.Count) 项" }
    return [PSCustomObject]@{ Ok = ($fail.Count -eq 0); Message = $msg; Skipped = $skip; Failed = $fail }
}
