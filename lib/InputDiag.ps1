# ============================================================================
#  InputDiag.ps1 -- 输入子系统诊断
#
#  针对的症状：游戏打开后"键盘暴走"（持续不断的错误键值输入）。
#
#  这类问题必须按输入栈自下而上逐层排查，任何单点假设都会误判：
#
#    硬件层    多个键盘 / 蓝牙 HID / 漂移的手柄 / USB 掉线重连
#    驱动层    键盘类过滤驱动 / Scancode Map 重映射 / Button Converter 虚拟设备
#    系统层    粘滞键·筛选键·切换键·鼠标键 / 键盘重复率
#    IME 层    中文输入法在 DirectInput 独占模式下的持续输入  ★ 东方系列最高发
#    应用层    DirectInput 的按程序配置 / 游戏帧率与刷新率不匹配 / vpatch 设置
#    干扰层    宏软件、远程控制、虚拟手柄注入
#
#  另外本模块会把原始数据完整导出，供后续做插件/二次分析使用 ——
#  报告里只给出结论，原始快照才是将来扩展的依据。
# ============================================================================
Set-StrictMode -Version 2.0

# ---------------------------------------------------------------------------
#  IME / 键盘布局
# ---------------------------------------------------------------------------
function Get-TrdImeState {
    <#
    .SYNOPSIS
        检查键盘布局与输入法状态，重点判断"能否切到英文"。
    .DESCRIPTION
        东方系列用 DirectInput 读键盘。中文输入法处于活动状态时，
        IME 会参与按键处理并可能持续产生输入；在独占全屏下尤其明显。
        社区通行做法是启动游戏前切到英文输入状态。

        但这里有一个常被忽略的前提：**系统里必须真的装了英文键盘布局**。
        只装中文键盘的系统，用户按 Win+空格 或 Ctrl+Shift 是切不出去的，
        于是"切英文"这个解法根本不成立 —— 表现为怎么弄都暴走。
        实测本机就是这种配置（Preload 里只有 00000804）。
    #>
    [CmdletBinding()]
    param()

    $layouts = New-Object System.Collections.ArrayList
    try {
        $pre = Get-ItemProperty 'HKCU:\Keyboard Layout\Preload' -ErrorAction Stop
        foreach ($p in $pre.PSObject.Properties) {
            if ($p.Name -like 'PS*') { continue }
            $code = [string]$p.Value
            $name = switch ($code) {
                '00000804' { '简体中文' } '00000404' { '繁体中文' }
                '00000411' { '日语' } '00000412' { '韩语' }
                '00000409' { '英语(美国)' } '00000809' { '英语(英国)' }
                '00000407' { '德语' } '0000040c' { '法语' }
                default { "未知($code)" }
            }
            $null = $layouts.Add([PSCustomObject]@{ Slot = $p.Name; Code = $code; Name = $name })
        }
    } catch { }

    $subs = @()
    try {
        $s = Get-ItemProperty 'HKCU:\Keyboard Layout\Substitutes' -ErrorAction Stop
        $subs = @($s.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' } |
                  ForEach-Object { "$($_.Name) -> $($_.Value)" })
    } catch { }

    $hasEnglish = @($layouts | Where-Object { $_.Code -like '00000?09' }).Count -gt 0
    $hasCjk = @($layouts | Where-Object { $_.Code -in '00000804', '00000404', '00000411', '00000412' }).Count -gt 0

    # IME 相关进程
    $imeProcs = @()
    try {
        $imeProcs = @(Get-Process -ErrorAction SilentlyContinue |
                      Where-Object { $_.ProcessName -match '^(ctfmon|ChsIME|JpnIME|KorIME|TextInputHost|Sogou|QQPinyin|Baidu|Youdao|Wetype|Weasel|Rime|SGTool)' } |
                      ForEach-Object { $_.ProcessName })
        $imeProcs = @($imeProcs | Sort-Object -Unique)
    } catch { }

    # 系统级"默认输入法"设置
    $hotkey = $null
    try { $hotkey = (Get-ItemProperty 'HKCU:\Keyboard Layout\Toggle' -Name 'Hotkey' -ErrorAction Stop).Hotkey } catch { }

    return [PSCustomObject]@{
        Layouts      = @($layouts)
        Substitutes  = $subs
        HasEnglish   = $hasEnglish
        HasCjk       = $hasCjk
        LayoutCount  = $layouts.Count
        ImeProcesses = $imeProcs
        ImeActive    = ($imeProcs.Count -gt 0)
        ToggleHotkey = $hotkey
        # 只有 CJK 布局、没有英文布局 = 用户无法切到英文输入
        CannotSwitchToEnglish = ($hasCjk -and -not $hasEnglish)
    }
}

# ---------------------------------------------------------------------------
#  辅助功能（会直接造成异常输入）
# ---------------------------------------------------------------------------
function Get-TrdAccessibilityState {
    <#
    .SYNOPSIS
        检查粘滞键 / 筛选键 / 切换键 / 鼠标键。
    .DESCRIPTION
        判断是否启用必须看 Flags 的【最低位】，不能看整个值是否非 0。
        实测本机四个键的 Flags 分别是 122 / 506 / 62 / 62，全都非 0，
        但最低位都是 0 —— 也就是说四项功能其实都是关闭的。
        按"非 0 即开启"判断会把一台正常的机器报成四项全开，
        这种误报比不查更糟。
        各项的 ON 标志位：
          StickyKeys    SKF_STICKYKEYSON   = 0x01
          FilterKeys    FKF_FILTERKEYSON   = 0x01
          ToggleKeys    TKF_TOGGLEKEYSON   = 0x01
          MouseKeys     MKF_MOUSEKEYSON    = 0x01
    #>
    [CmdletBinding()]
    param()

    $defs = @(
        @{ Key = 'Keyboard Response'; Name = '筛选键 (FilterKeys)';   Bit = 0x01
           Effect = '过滤或重放按键。配置异常时会把一次按键变成连续输入。' }
        @{ Key = 'StickyKeys';        Name = '粘滞键 (StickyKeys)';   Bit = 0x01
           Effect = '连续按 Shift 五次触发。会让修饰键"粘住"，产生意外的组合键。' }
        @{ Key = 'ToggleKeys';        Name = '切换键 (ToggleKeys)';   Bit = 0x01
           Effect = '按 CapsLock/NumLock 时发声并可能改变锁定状态。' }
        @{ Key = 'MouseKeys';         Name = '鼠标键 (MouseKeys)';    Bit = 0x01
           Effect = '用小键盘控制鼠标指针，会让小键盘输入被吞掉或错乱。' }
    )

    $items = New-Object System.Collections.ArrayList
    foreach ($d in $defs) {
        $flags = $null; $on = $false
        try {
            $v = Get-ItemProperty -Path ("HKCU:\Control Panel\Accessibility\" + $d.Key) -Name 'Flags' -ErrorAction Stop
            $flags = [int]$v.Flags
            $on = (($flags -band $d.Bit) -ne 0)
        } catch { }
        $null = $items.Add([PSCustomObject]@{
            Name    = $d.Name
            RegKey  = "HKCU:\Control Panel\Accessibility\$($d.Key)"
            Flags   = $flags
            Enabled = $on
            Effect  = $d.Effect
        })
    }

    $a = @($items)
    return [PSCustomObject]@{
        Items       = $a
        AnyEnabled  = (@($a | Where-Object { $_.Enabled }).Count -gt 0)
        EnabledList = @($a | Where-Object { $_.Enabled } | ForEach-Object { $_.Name })
    }
}

# ---------------------------------------------------------------------------
#  键盘重复率 / 过滤驱动 / Scancode Map
# ---------------------------------------------------------------------------
function Get-TrdKeyboardRepeatState {
    [CmdletBinding()]
    param()
    $r = [PSCustomObject]@{ Delay = $null; Speed = $null; IsFastest = $false }
    try {
        $v = Get-ItemProperty 'HKCU:\Control Panel\Keyboard' -ErrorAction Stop
        $r.Delay = [int]$v.KeyboardDelay
        $r.Speed = [int]$v.KeyboardSpeed
        # Speed=31 且 Delay=0/1 = 最快重复，会把"一个卡住的键"放大成输入洪水
        $r.IsFastest = ($r.Speed -ge 28 -and $r.Delay -le 1)
    } catch { }
    return $r
}

function Get-TrdInputFilterDrivers {
    <#
    .SYNOPSIS
        检查键盘/鼠标设备类的过滤驱动。
    .DESCRIPTION
        第三方程序（部分杀软、宏软件、外设驱动）会通过 UpperFilters /
        LowerFilters 把驱动挂进键盘栈。它们能看到并【改写】每一个按键，
        是幻影输入与按键错乱的高危来源。
        正常系统里键盘类只应有 kbdclass、鼠标类只应有 mouclass。
    #>
    [CmdletBinding()]
    param()

    $classes = @(
        @{ Guid = '{4d36e96b-e325-11ce-bfc1-08002be10318}'; Name = '键盘'; Normal = @('kbdclass') }
        @{ Guid = '{4d36e96c-e325-11ce-bfc1-08002be10318}'; Name = '鼠标'; Normal = @('mouclass') }
    )

    $out = New-Object System.Collections.ArrayList
    foreach ($c in $classes) {
        $base = "HKLM:\SYSTEM\CurrentControlSet\Control\Class\$($c.Guid)"
        if (-not (Test-Path -LiteralPath $base)) { continue }

        $p = Get-ItemProperty -LiteralPath $base -ErrorAction SilentlyContinue
        $up = @(); $low = @()
        if ($p) {
            if ($p.PSObject.Properties['UpperFilters']) { $up = @($p.UpperFilters) }
            if ($p.PSObject.Properties['LowerFilters']) { $low = @($p.LowerFilters) }
        }

        # 判定"是否第三方"不能靠硬编码白名单：
        # 实测鼠标类的 UpperFilters 是 hrdevmon,ksthunk，两者都不是 mouclass，
        # 按白名单会把一台完全正常的机器报成"挂了第三方驱动"。
        # 正确做法是找到驱动文件、看它的数字签名是不是微软签发的。
        $extra = New-Object System.Collections.ArrayList
        $all = @($up + $low | Where-Object { $_ })

        # 找驱动文件必须去【原生位数】的目录。
        # 在 64 位系统上以 32 位进程运行时，$env:windir\System32 会被静默
        # 重定向成 SysWOW64，而键盘/鼠标类的驱动（kbdclass.sys 等）只在真正的
        # System32\drivers 里。文件一找不到，下面的判定就落到
        # "找不到驱动文件，无法确认归属"，于是一台干净的机器凭空多出一条
        # 【高危：挂了第三方过滤驱动】——正是本工具最该避免的假阳性。
        # Get-TrdSystemDir 在 WOW64 下对 x64 返回 Sysnative，能读到真身。
        $dirNative = Get-TrdSystemDir -Bitness 'x64'
        if (-not $dirNative) { $dirNative = Get-TrdSystemDir -Bitness 'x86' }
        $dirX86 = Get-TrdSystemDir -Bitness 'x86'

        $lookupBases = New-Object System.Collections.ArrayList
        foreach ($d in @($dirNative, $dirX86)) {
            if (-not $d) { continue }
            if (-not $lookupBases.Contains((Join-Path $d 'drivers'))) {
                $null = $lookupBases.Add((Join-Path $d 'drivers'))
            }
            if (-not $lookupBases.Contains($d)) { $null = $lookupBases.Add($d) }
        }

        foreach ($drv in $all) {
            $signed = $null; $signer = $null; $path = $null
            # 注意变量名不能再用 $base —— 它是上面那个注册表类键，
            # PowerShell 的 foreach 不新建作用域，复用会把 RegKey 写坏。
            foreach ($lookupDir in $lookupBases) {
                $f = Join-Path $lookupDir ($drv + '.sys')
                if (Test-Path -LiteralPath $f) { $path = $f; break }
                $f2 = Join-Path $lookupDir ($drv + '.dll')
                if (Test-Path -LiteralPath $f2) { $path = $f2; break }
            }
            if ($path) {
                try {
                    $sg = Get-AuthenticodeSignature -LiteralPath $path -ErrorAction Stop
                    $signer = if ($sg.SignerCertificate) { [string]$sg.SignerCertificate.Subject } else { '' }
                    $signed = ($sg.Status -eq 'Valid' -and $signer -match 'Microsoft')
                } catch { }
            }
            # 微软签名的驱动视为系统组件，不算第三方
            if ($signed -eq $true) { continue }
            $null = $extra.Add([PSCustomObject]@{
                Driver = $drv; Path = $path; Signed = $signed; Signer = $signer
                Reason = $(if (-not $path) { '找不到驱动文件，无法确认归属' }
                           elseif ($signed -eq $false) { '驱动未通过微软签名校验' }
                           else { '无法校验签名' })
            })
        }

        $null = $out.Add([PSCustomObject]@{
            Class       = $c.Name
            RegKey      = $base
            UpperFilters = $up
            LowerFilters = $low
            ThirdParty  = $extra
            IsClean     = ($extra.Count -eq 0)
        })
    }
    return @($out)
}

function Get-TrdScancodeMap {
    <#
    .SYNOPSIS
        检查内核级键盘重映射（Scancode Map）。
    .DESCRIPTION
        这个值能把任意物理按键重映射成别的键，甚至禁用按键。
        被宏软件或用户手工写坏时，会出现"按 A 出 B"或"某个键一直按下"。
        正常系统上该值不存在。
    #>
    [CmdletBinding()]
    param()
    $key = 'HKLM:\SYSTEM\CurrentControlSet\Control\Keyboard Layout'
    $r = [PSCustomObject]@{ Present = $false; Bytes = 0; Hex = $null; Entries = @() }
    try {
        $v = Get-ItemProperty -LiteralPath $key -Name 'Scancode Map' -ErrorAction Stop
        $b = @($v.'Scancode Map')
        $r.Present = $true
        $r.Bytes = $b.Count
        $r.Hex = (($b | ForEach-Object { $_.ToString('X2') }) -join ' ')
        # 结构：8 字节头 + N 个 4 字节映射项 + 4 字节结束标记
        if ($b.Count -ge 12) {
            $items = New-Object System.Collections.ArrayList
            for ($i = 8; $i + 3 -lt $b.Count; $i += 4) {
                $to = [int]$b[$i] + ([int]$b[$i + 1] -shl 8)
                $from = [int]$b[$i + 2] + ([int]$b[$i + 3] -shl 8)
                if ($to -eq 0 -and $from -eq 0) { break }
                $null = $items.Add("物理键 0x{0:X2} -> 逻辑键 0x{1:X2}" -f $from, $to)
            }
            $r.Entries = @($items)
        }
    } catch { }
    return $r
}

# ---------------------------------------------------------------------------
#  设备枚举
# ---------------------------------------------------------------------------
function Get-TrdInputDeviceState {
    <#
    .SYNOPSIS
        枚举键盘、指针、手柄、蓝牙 HID 与虚拟转换设备。
    .DESCRIPTION
        需要关注的情况：
          * 键盘类设备多于 1 个物理键盘 —— 多出来的可能是虚拟设备
          * 存在 HID-compliant game controller —— 摇杆漂移会让菜单持续滚动，
            用户常误认为是键盘问题（东方同时读键盘和手柄）
          * BUTTONCONVERTER\\CONVERTEDDEVICE —— 由转换驱动生成的虚拟键盘，
            转换逻辑异常时会不断上报按键
          * 蓝牙 HID 设备处于已连接但无响应的状态时会持续发送输入
    #>
    [CmdletBinding()]
    param()

    $pnp = @()
    try { $pnp = @(Get-TrdWmiList 'Win32_PnPEntity') } catch { }

    $kb = @($pnp | Where-Object { $_.PNPClass -eq 'Keyboard' })
    $mouse = @($pnp | Where-Object { $_.PNPClass -eq 'Mouse' })
    $pad = @($pnp | Where-Object { $_.Name -match 'game controller|游戏控制器|Joystick|手柄' -or $_.PNPClass -eq 'XnaComposite' })
    # 蓝牙要区分"输入设备"与"普通蓝牙服务"。
    # 按 DeviceID 前缀统计会把手机、耳机、串口服务全算进来（实测数到 32 个），
    # 那个数字对排查毫无意义。只保留 HID 输入类。
    $bt = @($pnp | Where-Object {
        ($_.DeviceID -like 'BTHLEDEVICE*' -or $_.DeviceID -like 'BTHENUM*') -and
        ($_.PNPClass -in 'Keyboard', 'Mouse', 'HIDClass')
    })
    $conv = @($pnp | Where-Object { $_.DeviceID -match 'BUTTONCONVERTER|CONVERTEDDEVICE' })

    $badAny = @($pnp | Where-Object { $_.ConfigManagerErrorCode -ne 0 -and $_.PNPClass -match 'Keyboard|Mouse|HIDClass' })

    return [PSCustomObject]@{
        Keyboards     = @($kb | ForEach-Object { [PSCustomObject]@{ Name = $_.Name; DeviceID = $_.DeviceID; Status = $_.Status; ErrorCode = [int]$_.ConfigManagerErrorCode } })
        KeyboardCount = $kb.Count
        Mice          = @($mouse | ForEach-Object { [PSCustomObject]@{ Name = $_.Name; DeviceID = $_.DeviceID; Status = $_.Status } })
        Gamepads      = @($pad | ForEach-Object { [PSCustomObject]@{ Name = $_.Name; DeviceID = $_.DeviceID; Status = $_.Status; ErrorCode = [int]$_.ConfigManagerErrorCode } })
        GamepadCount  = $pad.Count
        BluetoothHid  = @($bt | ForEach-Object { [PSCustomObject]@{ Name = $_.Name; DeviceID = $_.DeviceID; Status = $_.Status } })
        BtCount       = $bt.Count
        ConvertedDev  = @($conv | ForEach-Object { [PSCustomObject]@{ Name = $_.Name; DeviceID = $_.DeviceID; Class = $_.PNPClass; Status = $_.Status } })
        ProblemInput  = @($badAny | ForEach-Object { [PSCustomObject]@{ Name = $_.Name; Class = $_.PNPClass; ErrorCode = [int]$_.ConfigManagerErrorCode } })
    }
}

# ---------------------------------------------------------------------------
#  DirectInput 应用状态 / 干扰进程 / 显示时序
# ---------------------------------------------------------------------------
function Get-TrdDirectInputAppState {
    <#
    .SYNOPSIS
        读取 DirectInput 为每个程序保存的配置。
    .DESCRIPTION
        键位于 HKCU\Software\Microsoft\DirectInput\<程序名>.EXE<哈希>，
        其中 UsesMapper 表示该程序是否启用 DirectInput 的动作映射器。
        启用映射器（=1）时，DINPUT 会按用户配置改写按键含义，
        如果那份映射被改坏，表现就是"按键完全不对"。
        另 MostRecentApplication 记录了最近一次使用 DInput 的程序。
        实测本机所有条目 UsesMapper 都是 0（未启用），属正常。
    #>
    [CmdletBinding()]
    param()

    $base = 'HKCU:\Software\Microsoft\DirectInput'
    $apps = New-Object System.Collections.ArrayList
    $mapperOn = New-Object System.Collections.ArrayList
    $recent = $null

    if (Test-Path -LiteralPath $base) {
        foreach ($k in @(Get-ChildItem -LiteralPath $base -ErrorAction SilentlyContinue)) {
            $nm = $k.PSChildName
            if ($nm -eq 'MostRecentApplication') {
                try {
                    $p = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
                    $recent = [PSCustomObject]@{ Name = [string]$p.Name; Id = [string]$p.Id }
                } catch { }
                continue
            }
            $usesMapper = $null
            try {
                $p = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction Stop
                if ($p.PSObject.Properties['UsesMapper']) {
                    $b = @($p.UsesMapper)
                    if ($b.Count -ge 4) { $usesMapper = ([int]$b[0] -ne 0) }
                }
            } catch { }

            $null = $apps.Add([PSCustomObject]@{ Key = $nm; UsesMapper = $usesMapper })
            if ($usesMapper -eq $true) { $null = $mapperOn.Add($nm) }
        }
    }

    return [PSCustomObject]@{
        AppCount       = $apps.Count
        Apps           = @($apps)
        MapperEnabled  = @($mapperOn)
        MostRecent     = $recent
    }
}

function Get-TrdInputInterference {
    <#
    .SYNOPSIS
        查找会注入或改写输入的常驻程序。
    .DESCRIPTION
        分五类：
          宏/按键工具   —— 直接注入按键
          远程控制      —— 会话输入重定向，连接残留时会有幻影输入
          虚拟手柄      —— 漂移的虚拟轴等同于持续按键
          外设驱动套件  —— 全局钩子改写按键
          音频/监控注入 —— 挂 D3D 钩子改变线程时序，间接影响输入采样
    #>
    [CmdletBinding()]
    param()

    $cats = @(
        @{ C = '宏 / 按键工具'; P = 'AutoHotkey|KeyTweak|按键精灵|QuickMacro|MacroRecorder|TinyTask|KeyManager' }
        @{ C = '远程控制';      P = 'SunloginClient|Sunlogin|ToDesk|TeamViewer|AnyDesk|Parsec|Moonlight|rustdesk|mstsc|RustDesk|GoToAssist|LogMeIn' }
        @{ C = '虚拟手柄';      P = 'vJoy|ViGEm|DS4Windows|BetterJoy|scptoolkit|SCToolkit|XOutput|x360ce|reWASD|JoyToKey|Xpadder|InputMapper|DS4' }
        # 注意不能用 GG 这种两字母缩写：它会匹配到 AggregatorHost（Windows 自带进程）。
        # 正则过松造成的误报比漏报更伤工具的可信度。
        @{ C = '外设驱动套件';  P = 'LGHUB|LogiTech|LogiOptions|LogiBolt|Razer|Synapse|Corsair|ICUE|SteelSeries|GGServices|GGWrapper|Roccat|Swarm' }
        @{ C = '画面/音频注入'; P = 'RTSS|RivaTuner|MSIAfterburner|Nahimic|SonicStudio|ReShade|SpecialK|Fraps|Bandicam|Dxtory' }
    )

    $found = New-Object System.Collections.ArrayList
    $procs = @()
    try { $procs = @(Get-Process -ErrorAction SilentlyContinue | Select-Object -ExpandProperty ProcessName -Unique) } catch { }

    foreach ($p in $procs) {
        foreach ($c in $cats) {
            if ($p -match $c.P) { $null = $found.Add([PSCustomObject]@{ Category = $c.C; Process = $p }); break }
        }
    }
    return @($found)
}

function Get-TrdDisplayTimingState {
    <#
    .SYNOPSIS
        采集刷新率与游戏帧率设置的匹配情况。
    .DESCRIPTION
        老引擎的输入是"每帧采样一次"。如果帧率失控（例如 120Hz 显示器上
        没有正确限帧），一次按键会被采样多帧，表现为菜单滚动飞快、
        像按键连发。vpatch 的存在正是为了修这个。
        这里记录刷新率与 vpatch 的 GameFPS 设置，供交叉判断。
    #>
    [CmdletBinding()]
    param([string]$GameFolder)

    $refresh = $null; $w = $null; $h = $null
    try {
        $g = @(Get-TrdWmiList 'Win32_VideoController') | Where-Object { $_.CurrentRefreshRate } | Select-Object -First 1
        if ($g) { $refresh = [int]$g.CurrentRefreshRate; $w = [int]$g.CurrentHorizontalResolution; $h = [int]$g.CurrentVerticalResolution }
    } catch { }

    $vpatchFps = $null; $vpatchVsync = $null; $vpatchSleep = $null; $vpatchPath = $null
    if ($GameFolder) {
        $vp = Join-Path $GameFolder 'vpatch.ini'
        if (Test-Path -LiteralPath $vp) {
            $vpatchPath = $vp
            try {
                foreach ($line in [System.IO.File]::ReadAllLines($vp, [System.Text.Encoding]::GetEncoding(936))) {
                    if ($line -match '^\s*GameFPS\s*=\s*(\d+)')            { $vpatchFps = [int]$Matches[1] }
                    elseif ($line -match '^\s*Vsync\s*=\s*(\d+)')          { $vpatchVsync = [int]$Matches[1] }
                    elseif ($line -match '^\s*SleepType\s*=\s*(\d+)')      { $vpatchSleep = [int]$Matches[1] }
                }
            } catch { }
        }
    }

    return [PSCustomObject]@{
        RefreshHz    = $refresh
        Width        = $w
        Height       = $h
        HighRefresh  = ($refresh -and $refresh -gt 60)
        VpatchIni    = $vpatchPath
        VpatchGameFPS = $vpatchFps
        VpatchVsync  = $vpatchVsync
        VpatchSleep  = $vpatchSleep
        FpsMismatch  = ($refresh -and $refresh -gt 60 -and $null -eq $vpatchFps)
    }
}

# ---------------------------------------------------------------------------
#  总入口
# ---------------------------------------------------------------------------
function Get-TrdInputDiagnostics {
    <#
    .SYNOPSIS
        采集完整的输入子系统状态。
    .PARAMETER GameFolder
        游戏目录，用于读取 vpatch.ini 的帧率设置。
    .OUTPUTS
        结构化对象树；其中 Raw 部分为原始数据，供后续插件/二次分析使用。
    #>
    [CmdletBinding()]
    param([string]$GameFolder)

    # 每一项都独立 try/catch：输入子系统里任何一项取不到（老系统缺键、
    # 无 Bluetooth 栈、游戏目录不可读）都不该让整轮诊断中断。
    $ime = $null;   try { $ime   = Get-TrdImeState } catch { }
    $acc = $null;   try { $acc   = Get-TrdAccessibilityState } catch { }
    $rep = $null;   try { $rep   = Get-TrdKeyboardRepeatState } catch { }
    $filt = @();    try { $filt  = @(Get-TrdInputFilterDrivers) } catch { }
    $scan = $null;  try { $scan  = Get-TrdScancodeMap } catch { }
    $dev = $null;   try { $dev   = Get-TrdInputDeviceState } catch { }
    $dinput = $null;try { $dinput= Get-TrdDirectInputAppState } catch { }
    $inter = @();   try { $inter = @(Get-TrdInputInterference) } catch { }
    $timing = $null;try { $timing= Get-TrdDisplayTimingState -GameFolder $GameFolder } catch { }

    return [PSCustomObject]@{
        Ime          = $ime
        Accessibility = $acc
        KeyboardRepeat = $rep
        FilterDrivers = $filt
        ScancodeMap  = $scan
        Devices      = $dev
        DirectInput  = $dinput
        Interference = $inter
        Timing       = $timing
    }
}

function Export-TrdInputSnapshot {
    <#
    .SYNOPSIS
        把输入诊断的原始数据导出为 JSON，供后续插件/离线分析。
    .DESCRIPTION
        报告面向"给人看"，快照面向"给程序用"。将来要做输入相关的改进
        （换用 Raw Input 接管、做按键录制回放、比对不同机器的差异），
        这份快照就是现成的数据基础。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$InputDiag,
        [Parameter(Mandatory = $true)][string]$OutDir,
        [string]$FilePrefix = '输入诊断快照'
    )

    if (-not (Test-Path -LiteralPath $OutDir)) { $null = New-Item -ItemType Directory -Path $OutDir -Force }

    $payload = [PSCustomObject]@{
        Schema      = 'TouhouRuntimeDoctor/input-snapshot'
        Version     = 1
        CollectedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        Machine     = [PSCustomObject]@{
            Computer  = $env:COMPUTERNAME
            User      = $env:USERNAME
            PsVersion = [string]$PSVersionTable.PSVersion
            Is64OS    = [bool]$script:TRD.Is64OS
        }
        Input       = $InputDiag
    }

    $json = ConvertTo-Json -InputObject $payload -Depth 12
    # 还原 \uXXXX 转义，让快照人能直接读
    $json = [regex]::Replace($json, '\\u([0-9a-fA-F]{4})', {
        param($m) [char][Convert]::ToInt32($m.Groups[1].Value, 16)
    })

    $p = Join-Path $OutDir ("{0}_{1}.json" -f $FilePrefix, (Get-Date -Format 'yyyyMMdd-HHmmss'))
    [System.IO.File]::WriteAllText($p, $json, (New-Object System.Text.UTF8Encoding($false)))
    return $p
}
