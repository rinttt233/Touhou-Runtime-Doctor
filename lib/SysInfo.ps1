# ============================================================================
#  SysInfo.ps1 -- 设备与系统信息采集
#
#  目标：一次性、全面地取到"这台机器到底是什么配置、有没有异常设备"，
#        用于排查游戏/软件运行问题，也用于跨机器对比。
#
#  设计要点：
#   1. 全部走 Get-TrdWmiObject（内部按 PowerShell 版本选 CIM 还是 WMI），
#      保证在 Windows 7 + WMF3 上也能跑。
#   2. 属性访问一律经过 Get-TrdWmiValue。CIM 与 WMI 返回的对象类型不同，
#      缺属性时一个返回 $null、一个在 StrictMode 下抛异常，必须统一兜住。
#   3. 只读。本文件不做任何修改动作（除了 powercfg 的只读查询）。
#   4. Win32_Product 绝对不用 —— 它会触发 MSI 重新配置，极慢且会改系统状态。
# ============================================================================
Set-StrictMode -Version 2.0

# ConfigManagerErrorCode 解码表。
# 这张表是"设备为什么工作不正常"最直接的答案，比任何猜测都有用。
$script:TRD_CM_ERROR = @{
    0  = '工作正常'
    1  = '设备未正确配置（缺少驱动或配置错误）'
    2  = '无法加载该设备的驱动程序'
    3  = '驱动程序已损坏，或系统内存/资源不足'
    4  = '设备信息不完整或已损坏'
    5  = '设备需要重新启动计算机才能生效'
    6  = '该设备的启动配置与其他设备冲突'
    7  = '该设备缺少必要的资源分配'
    8  = '设备驱动加载器找不到该设备'
    9  = '设备信息已损坏，需要重新安装驱动'
    10 = '设备无法启动（驱动加载失败）'
    11 = '设备失败（驱动返回了错误）'
    12 = '可用资源不足，无法启动该设备'
    13 = '设备无法被识别'
    14 = '设备需要重启后才能正常工作'
    15 = '设备正在重新枚举，状态可能不准确'
    16 = '设备使用的资源未被全部检测到'
    17 = '设备请求了未知资源类型'
    18 = '需要重新安装该设备的驱动程序'
    19 = '注册表中的设备配置已损坏'
    20 = '设备配置无效'
    21 = 'Windows 正在移除该设备'
    22 = '设备已被禁用（在设备管理器中被停用）'
    23 = '设备未被正确安装'
    24 = '设备不存在、工作不正常，或未安装全部驱动'
    25 = '设备被其他设备占用'
    26 = '设备未被正确加载'
    27 = '设备没有有效的日志配置'
    28 = '设备的驱动程序未安装  ★ 最常见：驱动缺失'
    29 = '设备已被固件（BIOS/UEFI）禁用'
    30 = '设备使用了另一设备的 IRQ'
    31 = 'Windows 无法加载该设备所需的驱动程序'
    32 = '该设备的驱动启动类型被禁用'
    33 = '设备报告了未知的冲突'
    34 = '设备需要手动配置'
    35 = '设备的 BIOS 未提供必要的资源信息'
    36 = '设备正被系统用于启动'
    37 = '设备无法初始化'
    38 = '设备驱动程序的上一实例仍在内存中'
    39 = '设备驱动程序加载失败'
    40 = '设备驱动程序的注册表信息无效'
    41 = '设备未被系统识别'
    42 = '系统中已存在同名设备，存在重复'
    43 = 'Windows 已停止该设备，因为它报告了问题  ★ 显卡驱动异常常见'
    44 = '设备已被用户或程序停止'
    45 = '设备当前未连接'
    46 = '系统正在关闭，设备不可用'
    47 = '设备已准备就绪，等待移除'
    48 = '设备驱动已被阻止加载（可能因兼容性或安全策略）'
    49 = '系统未加载该设备的驱动，因为它被认为无必要'
}

function Get-TrdWmiValue {
    <#
    .SYNOPSIS
        安全读取 WMI/CIM 对象的属性值。
    .DESCRIPTION
        CIM 对象（Get-CimInstance）与 WMI 对象（Get-WmiObject）的属性存储方式
        不同，且缺少属性时的行为也不一致：一个返回 $null，
        另一个在 Set-StrictMode 下会直接抛 PropertyNotFoundException。
        设备信息采集要遍历上百个字段，任何一个缺字段都可能中断整轮采集，
        因此统一从这里取值。
    #>
    param($Object, [Parameter(Mandatory = $true)][string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    try {
        $p = $Object.PSObject.Properties[$Name]
        if ($p) {
            $v = $p.Value
            if ($null -ne $v) { return $v }
        }
    } catch { }
    return $Default
}

function Get-TrdWmiList {
    <#
    .SYNOPSIS
        安全地取一个 WMI 类的全部实例，失败时返回空数组（不抛异常）。
    .DESCRIPTION
        设备信息采集会尝试很多类，其中不少在特定机器上并不存在
        （例如台式机没有 Win32_Battery、Server 没有 root\wmi 显示器信息）。
        逐个 try/catch 比让整轮采集中断合理得多。
    #>
    param(
        [Parameter(Mandatory = $true)][string]$ClassName,
        [string]$Namespace = ''
    )
    try {
        if ($Namespace) {
            if (Get-Command -Name 'Get-CimInstance' -ErrorAction SilentlyContinue) {
                return @(Get-CimInstance -Namespace $Namespace -ClassName $ClassName -ErrorAction Stop)
            }
            return @(Get-WmiObject -Namespace $Namespace -Class $ClassName -ErrorAction Stop)
        }
        $r = Get-TrdWmiObject -ClassName $ClassName
        return @($r)
    } catch {
        return @()
    }
}

function ConvertFrom-TrdUInt16String {
    <#
    .SYNOPSIS
        把 EDID 里以 uint16 数组返回的字符串还原成可读文本。
    .DESCRIPTION
        WmiMonitorID 的 ManufacturerName / UserFriendlyName 等字段返回的是
        每个字符一个 ushort 的数组（例如 76,69,78 = "LEN"）。
        直接 ToString() 会打印成一串数字，必须逐字符转换并去掉结尾的 0 填充。
    #>
    param($Array)
    if ($null -eq $Array) { return $null }
    $s = ''
    foreach ($v in @($Array)) {
        $n = 0
        try { $n = [int]$v } catch { continue }
        if ($n -le 0) { continue }
        if ($n -lt 32 -or $n -gt 0xFFFF) { continue }
        $s += [char]$n
    }
    $s = $s.Trim()
    if ($s) { return $s }
    return $null
}

# ---------------------------------------------------------------------------
#  身份 / 主板 / BIOS
# ---------------------------------------------------------------------------
function Get-TrdSysIdentity {
    $cs  = @(Get-TrdWmiList 'Win32_ComputerSystem')
    $csp = @(Get-TrdWmiList 'Win32_ComputerSystemProduct')
    $bb  = @(Get-TrdWmiList 'Win32_BaseBoard')
    $bio = @(Get-TrdWmiList 'Win32_BIOS')
    $se  = @(Get-TrdWmiList 'Win32_SystemEnclosure')

    $c = if ($cs.Count -gt 0) { $cs[0] } else { $null }
    $p = if ($csp.Count -gt 0) { $csp[0] } else { $null }
    $b = if ($bb.Count -gt 0) { $bb[0] } else { $null }
    $o = if ($bio.Count -gt 0) { $bio[0] } else { $null }
    $e = if ($se.Count -gt 0) { $se[0] } else { $null }

    $biosDate = $null
    try {
        $raw = Get-TrdWmiValue $o 'ReleaseDate'
        if ($raw -is [datetime]) { $biosDate = $raw }
        elseif ($raw) {
            $s = [string]$raw
            if ($s -match '^\d{14}') { $biosDate = [Management.ManagementDateTimeConverter]::ToDateTime($s) }
            else { try { $biosDate = [datetime]::Parse($s) } catch { } }
        }
    } catch { }

    $chassis = @()
    try { $chassis = @(Get-TrdWmiValue $e 'ChassisTypes' | ForEach-Object { [int]$_ }) } catch { }
    $chassisName = switch ($chassis) {
        3  { '台式机' } 4 { '低矮台式机' } 5 { '披萨盒式' } 6 { '迷你塔式' } 7 { '塔式' }
        8  { '便携式' } 9 { '笔记本' } 10 { '笔记本' } 11 { '手持设备' } 12 { '对接站' }
        13 { '一体机' } 14 { '子笔记本' } 15 { '空间节省型' } 16 { '午餐盒式' }
        17 { '主系统机箱' } 18 { '扩展机箱' } 21 { '外围机箱' } 30 { '平板' } 31 { '可翻转笔记本' }
        default { if ($chassis.Count -gt 0) { "类型 $($chassis -join ',')" } else { $null } }
    }

    return [PSCustomObject]@{
        ComputerName   = [string](Get-TrdWmiValue $c 'Name')
        Manufacturer   = [string](Get-TrdWmiValue $c 'Manufacturer')
        Model          = [string](Get-TrdWmiValue $c 'Model')
        SystemType     = [string](Get-TrdWmiValue $c 'SystemType')
        Domain         = [string](Get-TrdWmiValue $c 'Domain')
        Workgroup      = [string](Get-TrdWmiValue $c 'Workgroup')
        LoggedUser     = [string](Get-TrdWmiValue $c 'UserName')
        TotalPhysMB    = $(try { [Math]::Round([double](Get-TrdWmiValue $c 'TotalPhysicalMemory') / 1MB, 0) } catch { 0 })
        ProductName    = [string](Get-TrdWmiValue $p 'Name')
        ProductVendor  = [string](Get-TrdWmiValue $p 'Vendor')
        UUID           = [string](Get-TrdWmiValue $p 'UUID')
        IdentifyingNum = [string](Get-TrdWmiValue $p 'IdentifyingNumber')
        ChassisType    = $chassisName
        ChassisSerial  = [string](Get-TrdWmiValue $e 'SerialNumber')
        BoardVendor    = [string](Get-TrdWmiValue $b 'Manufacturer')
        BoardProduct   = [string](Get-TrdWmiValue $b 'Product')
        BoardVersion   = [string](Get-TrdWmiValue $b 'Version')
        BoardSerial    = [string](Get-TrdWmiValue $b 'SerialNumber')
        BiosVendor     = [string](Get-TrdWmiValue $o 'Manufacturer')
        BiosVersion    = [string](Get-TrdWmiValue $o 'SMBIOSBIOSVersion')
        BiosDate       = $biosDate
        BiosMode       = $(try {
                            $pf = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control' -Name 'PEFirmwareType' -ErrorAction Stop
                            switch ([int]$pf.PEFirmwareType) { 1 { 'UEFI' } 2 { 'BIOS (Legacy)' } default { $null } }
                          } catch { $null })
        SecureBoot     = $(try {
                            $sb = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State' -Name 'UEFISecureBootEnabled' -ErrorAction Stop
                            ([int]$sb.UEFISecureBootEnabled -eq 1)
                          } catch { $null })
    }
}

# ---------------------------------------------------------------------------
#  操作系统
# ---------------------------------------------------------------------------
function Get-TrdSysOsInfo {
    $os = @(Get-TrdWmiList 'Win32_OperatingSystem')
    $o = if ($os.Count -gt 0) { $os[0] } else { $null }
    $cs = @(Get-TrdWmiList 'Win32_ComputerSystem')
    $c = if ($cs.Count -gt 0) { $cs[0] } else { $null }

    $install = $null; $boot = $null
    try {
        $r = Get-TrdWmiValue $o 'InstallDate'
        if ($r) { $install = [Management.ManagementDateTimeConverter]::ToDateTime([string]$r) }
    } catch { }
    try {
        $r = Get-TrdWmiValue $o 'LastBootUpTime'
        if ($r) { $boot = [Management.ManagementDateTimeConverter]::ToDateTime([string]$r) }
    } catch { }

    $uptime = $null
    if ($boot) { $uptime = (Get-Date) - $boot }

    $tz = @(Get-TrdWmiList 'Win32_TimeZone')
    $t = if ($tz.Count -gt 0) { $tz[0] } else { $null }

    $loc = Get-TrdSystemLocale

    return [PSCustomObject]@{
        Caption        = [string](Get-TrdWmiValue $o 'Caption')
        Version        = [string](Get-TrdWmiValue $o 'Version')
        Build          = [string](Get-TrdWmiValue $o 'BuildNumber')
        Architecture   = [string](Get-TrdWmiValue $o 'OSArchitecture')
        ServicePack    = [string](Get-TrdWmiValue $o 'ServicePackMajorVersion')
        InstallDate    = $install
        LastBoot       = $boot
        Uptime         = $uptime
        TimeZone       = [string](Get-TrdWmiValue $t 'Caption')
        SystemLocale   = $loc.Name
        AcpCodePage    = $loc.ACP
        SystemDrive    = [string](Get-TrdWmiValue $o 'SystemDrive')
        WindowsDir     = [string](Get-TrdWmiValue $o 'WindowsDirectory')
        BootDevice     = [string](Get-TrdWmiValue $o 'BootDevice')
        TotalMemMB     = $(try { [Math]::Round([double](Get-TrdWmiValue $o 'TotalVisibleMemorySize') / 1KB, 0) } catch { 0 })
        FreeMemMB      = $(try { [Math]::Round([double](Get-TrdWmiValue $o 'FreePhysicalMemory') / 1KB, 0) } catch { 0 })
        TotalVirtMB    = $(try { [Math]::Round([double](Get-TrdWmiValue $o 'TotalVirtualMemorySize') / 1KB, 0) } catch { 0 })
        FreeVirtMB     = $(try { [Math]::Round([double](Get-TrdWmiValue $o 'FreeVirtualMemory') / 1KB, 0) } catch { 0 })
        AutoUpdate     = $null
        Is64Os         = [bool]$script:TRD.Is64OS
        PsVersion      = [string]$PSVersionTable.PSVersion
    }
}

# ---------------------------------------------------------------------------
#  CPU
# ---------------------------------------------------------------------------
function Get-TrdSysCpu {
    $cpus = @(Get-TrdWmiList 'Win32_Processor')
    $caches = @(Get-TrdWmiList 'Win32_CacheMemory')
    $out = New-Object System.Collections.ArrayList

    foreach ($c in $cpus) {
        if (-not $c) { continue }

        # 缓存明细：去重后展示。
        # 两个必须注意的点：
        #  1) Win32_CacheMemory 的 Level / CacheType 是数字，但 Purpose 是
        #     【字符串】（例如 "L1 Cache"）。早期误把 Purpose 当数字转 int，
        #     直接抛 "Cannot convert value L1 Cache to type System.Int32"。
        #  2) 每个核心都会重复上报同一组缓存（本机 8 条其实只有 4 种），
        #     不去重会输出一堆无意义的重复行。
        $cacheSeen = @{}
        $myCaches = @()
        foreach ($ca in $caches) {
            if (-not $ca) { continue }
            $lvlRaw = Get-TrdWmiValue $ca 'Level'
            $lvlNum = 0
            try { $lvlNum = [int]$lvlRaw } catch { $lvlNum = 0 }
            $lvlName = switch ($lvlNum) { 3 { 'L1' } 4 { 'L2' } 5 { 'L3' } default { "Level$lvlRaw" } }

            $typeNum = 0
            try { $typeNum = [int](Get-TrdWmiValue $ca 'CacheType' -Default 0) } catch { $typeNum = 0 }
            $typeName = switch ($typeNum) {
                3 { '指令' } 4 { '数据' } 5 { '统一' }
                default {
                    # 数字类型拿不到时退回 WMI 自己给的字符串
                    $p = [string](Get-TrdWmiValue $ca 'Purpose')
                    if ($p) { $p } else { '统一' }
                }
            }

            $szKB = 0
            try { $szKB = [int](Get-TrdWmiValue $ca 'MaxCacheSize' -Default 0) } catch { $szKB = 0 }

            $key = "$lvlName|$typeName|$szKB"
            if ($cacheSeen.ContainsKey($key)) { continue }
            $cacheSeen[$key] = $true

            $myCaches += [PSCustomObject]@{
                Level   = $lvlName
                Type    = $typeName
                SizeKB  = $szKB
                Purpose = [string](Get-TrdWmiValue $ca 'Purpose')
            }
        }

        $null = $out.Add([PSCustomObject]@{
            Name           = ([string](Get-TrdWmiValue $c 'Name')).Trim()
            Manufacturer   = [string](Get-TrdWmiValue $c 'Manufacturer')
            Description    = [string](Get-TrdWmiValue $c 'Description')
            Architecture   = $(switch ([int](Get-TrdWmiValue $c 'Architecture' -Default 0)) {
                                0 { 'x86' } 5 { 'ARM' } 9 { 'x64' } 12 { 'ARM64' } default { '未知' } })
            Cores          = [int](Get-TrdWmiValue $c 'NumberOfCores' -Default 0)
            Threads        = [int](Get-TrdWmiValue $c 'NumberOfLogicalProcessors' -Default 0)
            MaxClockMHz    = [int](Get-TrdWmiValue $c 'MaxClockSpeed' -Default 0)
            CurClockMHz    = [int](Get-TrdWmiValue $c 'CurrentClockSpeed' -Default 0)
            SocketDesignation = [string](Get-TrdWmiValue $c 'SocketDesignation')
            Stepping       = [string](Get-TrdWmiValue $c 'Stepping')
            Virtualization = $(try { [bool](Get-TrdWmiValue $c 'VirtualizationFirmwareEnabled') } catch { $null })
            SecondLevelAddrExt = $(try { [bool](Get-TrdWmiValue $c 'SecondLevelAddressTranslationExtensions') } catch { $null })
            DataWidth      = [int](Get-TrdWmiValue $c 'DataWidth' -Default 0)
            L2CacheKB      = [int](Get-TrdWmiValue $c 'L2CacheSize' -Default 0)
            L3CacheKB      = [int](Get-TrdWmiValue $c 'L3CacheSize' -Default 0)
            Caches         = @($myCaches)
            Status         = [string](Get-TrdWmiValue $c 'Status')
        })
    }
    return @($out)
}

# ---------------------------------------------------------------------------
#  内存
# ---------------------------------------------------------------------------
function Get-TrdSysMemory {
    $arr   = @(Get-TrdWmiList 'Win32_PhysicalMemoryArray')
    $slots = @(Get-TrdWmiList 'Win32_PhysicalMemory')
    $pf    = @(Get-TrdWmiList 'Win32_PageFileUsage')

    $a = if ($arr.Count -gt 0) { $arr[0] } else { $null }

    $slotList = New-Object System.Collections.ArrayList
    foreach ($s in $slots) {
        if (-not $s) { continue }
        $capGB = 0
        try { $capGB = [Math]::Round([double](Get-TrdWmiValue $s 'Capacity') / 1GB, 0) } catch { }

        $typeName = switch ([int](Get-TrdWmiValue $s 'MemoryType' -Default 0)) {
            20 { 'DDR' } 21 { 'DDR2' } 24 { 'DDR3' } 26 { 'DDR4' }
            34 { 'DDR5' } 0 { '未知（由 SMBIOS 类型推断）' } default { '其他' }
        }
        $formName = switch ([int](Get-TrdWmiValue $s 'FormFactor' -Default 0)) {
            8 { 'DIMM' } 12 { 'SODIMM' } 13 { 'SRIMM' } default { '' }
        }

        $null = $slotList.Add([PSCustomObject]@{
            BankLabel   = [string](Get-TrdWmiValue $s 'BankLabel')
            DeviceLocator = [string](Get-TrdWmiValue $s 'DeviceLocator')
            CapacityGB  = $capGB
            SpeedMHz    = [int](Get-TrdWmiValue $s 'Speed' -Default 0)
            ConfiguredMHz = [int](Get-TrdWmiValue $s 'ConfiguredClockSpeed' -Default 0)
            Manufacturer = ([string](Get-TrdWmiValue $s 'Manufacturer')).Trim()
            PartNumber  = ([string](Get-TrdWmiValue $s 'PartNumber')).Trim()
            SerialNumber = ([string](Get-TrdWmiValue $s 'SerialNumber')).Trim()
            MemoryType  = $typeName
            SmbiosType  = [int](Get-TrdWmiValue $s 'SMBIOSMemoryType' -Default 0)
            FormFactor  = $formName
            VoltageMV   = $(try { [int](Get-TrdWmiValue $s 'ConfiguredVoltage' -Default 0) } catch { 0 })
        })
    }

    $pfList = New-Object System.Collections.ArrayList
    foreach ($p in $pf) {
        if (-not $p) { continue }
        $null = $pfList.Add([PSCustomObject]@{
            Name        = [string](Get-TrdWmiValue $p 'Name')
            AllocMB     = [int](Get-TrdWmiValue $p 'AllocatedBaseSize' -Default 0)
            CurrentMB   = [int](Get-TrdWmiValue $p 'CurrentUsage' -Default 0)
            PeakMB      = [int](Get-TrdWmiValue $p 'PeakUsage' -Default 0)
        })
    }

    $slotCount = 0
    try { $slotCount = [int](Get-TrdWmiValue $a 'MemoryDevices' -Default 0) } catch { }

    return [PSCustomObject]@{
        TotalGB      = $(try { [Math]::Round([double](Get-TrdWmiValue $a 'MaxCapacityEx' -Default 0) / 1MB, 0) } catch { 0 })
        SlotCount    = $slotCount
        UsedSlots    = $slotList.Count
        Slots        = @($slotList)
        PageFiles    = @($pfList)
        InstalledGB  = [Math]::Round((@($slotList | Measure-Object -Property CapacityGB -Sum).Sum), 0)
        SpeedSummary = $(if ($slotList.Count -gt 0) { ($slotList | ForEach-Object { "$($_.SpeedMHz)MHz" } | Sort-Object -Unique) -join '/' } else { '' })
    }
}

# ---------------------------------------------------------------------------
#  显示器（EDID）
# ---------------------------------------------------------------------------
function Get-TrdSysMonitors {
    $ids = @(Get-TrdWmiList -ClassName 'WmiMonitorID' -Namespace 'root\wmi')
    $params = @(Get-TrdWmiList -ClassName 'WmiMonitorBasicDisplayParams' -Namespace 'root\wmi')
    $conn = @(Get-TrdWmiList -ClassName 'WmiMonitorConnectionParams' -Namespace 'root\wmi')
    $dt = @(Get-TrdWmiList 'Win32_DesktopMonitor')

    $out = New-Object System.Collections.ArrayList

    foreach ($m in $ids) {
        if (-not $m) { continue }
        $inst = [string](Get-TrdWmiValue $m 'InstanceName')

        $vendor = ConvertFrom-TrdUInt16String (Get-TrdWmiValue $m 'ManufacturerName')
        $friendly = ConvertFrom-TrdUInt16String (Get-TrdWmiValue $m 'UserFriendlyName')
        $prodCode = ConvertFrom-TrdUInt16String (Get-TrdWmiValue $m 'ProductCodeID')
        $serial = ConvertFrom-TrdUInt16String (Get-TrdWmiValue $m 'SerialNumberID')

        $wcm = 0; $hcm = 0; $hasParams = $false
        foreach ($p in $params) {
            if (-not $p) { continue }
            if ([string](Get-TrdWmiValue $p 'InstanceName') -like ($inst -replace '_0$', '*')) {
                $wcm = [int](Get-TrdWmiValue $p 'MaxHorizontalImageSize' -Default 0)
                $hcm = [int](Get-TrdWmiValue $p 'MaxVerticalImageSize' -Default 0)
                $hasParams = $true
                break
            }
        }

        $diagInch = $null
        if ($hasParams -and $wcm -gt 0 -and $hcm -gt 0) {
            $diagInch = [Math]::Round([Math]::Sqrt(($wcm * $wcm) + ($hcm * $hcm)) / 2.54, 1)
        }

        $outConn = ''
        foreach ($cv in $conn) {
            if (-not $cv) { continue }
            if ([string](Get-TrdWmiValue $cv 'InstanceName') -like ($inst -replace '_0$', '*')) {
                $outConn = switch ([int](Get-TrdWmiValue $cv 'VideoOutputTechnology' -Default -1)) {
                    0  { 'VGA (D-Sub)' } 1 { 'S-Video' } 2 { '复合视频' } 3 { '分量视频' }
                    4  { 'DVI' } 5 { 'HDMI' } 6 { 'LVDS (内置)' } 8 { 'D-Jpn' }
                    9  { 'SDI' } 10 { 'DisplayPort 外接' } 11 { 'DisplayPort 内置' }
                    12 { 'UDI 外接' } 13 { 'UDI 内置' } 14 { 'SDTV Dongle' }
                    15 { 'Miracast' } 2147483648 { '内置面板' }
                    default { "类型 $($_)" }
                }
                break
            }
        }

        $null = $out.Add([PSCustomObject]@{
            InstanceName = $inst
            Vendor       = $vendor
            Name         = $friendly
            ProductCode  = $prodCode
            Serial       = $serial
            Year         = [int](Get-TrdWmiValue $m 'YearOfManufacture' -Default 0)
            Week         = [int](Get-TrdWmiValue $m 'WeekOfManufacture' -Default 0)
            WidthCm      = $wcm
            HeightCm     = $hcm
            DiagonalInch = $diagInch
            Connection   = $outConn
        })
    }

    # 兜底：EDID 拿不到时用 Win32_DesktopMonitor 的信息
    if ($out.Count -eq 0) {
        foreach ($d in $dt) {
            if (-not $d) { continue }
            $null = $out.Add([PSCustomObject]@{
                InstanceName = [string](Get-TrdWmiValue $d 'DeviceID')
                Vendor       = [string](Get-TrdWmiValue $d 'MonitorManufacturer')
                Name         = [string](Get-TrdWmiValue $d 'Name')
                ProductCode  = ''; Serial = ''
                Year         = 0; Week = 0
                WidthCm      = 0; HeightCm = 0; DiagonalInch = $null
                Connection   = ''
            })
        }
    }

    return @($out)
}

# ---------------------------------------------------------------------------
#  存储
# ---------------------------------------------------------------------------
function Get-TrdSysStorage {
    $drives = @(Get-TrdWmiList 'Win32_DiskDrive')
    $parts  = @(Get-TrdWmiList 'Win32_DiskPartition')
    $vols   = @(Get-TrdWmiList 'Win32_LogicalDisk')

    # MSFT_PhysicalDisk 只在 Windows 8+ 的 Storage 命名空间里有，提供 SSD/HDD 与健康状态
    $msft = @(Get-TrdWmiList -ClassName 'MSFT_PhysicalDisk' -Namespace 'root\Microsoft\Windows\Storage')

    # 把 MSFT_PhysicalDisk 索引起来，便于按序列号精确匹配。
    # 不能只按容量匹配：MSFT 报的是出厂原始容量，Win32_DiskDrive 报的是
    # 四舍五入后的可用容量，同一块盘两者能差好几 MB
    # （实测 1024209543168 vs 1024203640320，差 5.9 MB），
    # 用"差值 < 1MB"去匹配会永远匹配不上，健康状态就一直是"未知"。
    $msftBySerial = @{}
    foreach ($m in $msft) {
        if (-not $m) { continue }
        $sn = ([string](Get-TrdWmiValue $m 'SerialNumber')).Trim()
        $key = ($sn -replace '[^0-9A-Za-z]', '').ToUpperInvariant()
        if ($key) { $msftBySerial[$key] = $m }
    }

    $diskList = New-Object System.Collections.ArrayList
    foreach ($d in $drives) {
        if (-not $d) { continue }
        $sizeGB = 0
        try { $sizeGB = [Math]::Round([double](Get-TrdWmiValue $d 'Size') / 1GB, 0) } catch { }

        $media = ''
        try {
            $mt = [int](Get-TrdWmiValue $d 'MediaType' -Default 0)
            $media = switch ($mt) { 3 { '硬盘 (HDD)' } 4 { '固态硬盘 (SSD)' } 5 { 'SCM' } default { '' } }
        } catch { }

        # 从 MSFT_PhysicalDisk 补充更可靠的介质类型与健康状态
        $health = $null
        $serial = ([string](Get-TrdWmiValue $d 'SerialNumber')).Trim()
        $dSize = 0
        try { $dSize = [double](Get-TrdWmiValue $d 'Size' -Default 0) } catch { }

        # 1) 先按序列号精确匹配
        $match = $null
        $snKey = ($serial -replace '[^0-9A-Za-z]', '').ToUpperInvariant()
        if ($snKey -and $msftBySerial.ContainsKey($snKey)) { $match = $msftBySerial[$snKey] }

        # 2) 序列号匹配不上时，退回按容量近似匹配（容差放宽到 1%）
        if (-not $match -and $dSize -gt 0) {
            foreach ($m in $msft) {
                if (-not $m) { continue }
                $mSize = 0
                try { $mSize = [double](Get-TrdWmiValue $m 'Size' -Default 0) } catch { }
                if ($mSize -gt 0 -and ([Math]::Abs($mSize - $dSize) / $dSize) -lt 0.01) { $match = $m; break }
            }
        }

        # 总线类型：Win32_DiskDrive 的 InterfaceType 常常是空的，
        # 而 MSFT_PhysicalDisk 的 BusType 更完整（能区分 SATA / NVMe / USB）
        $busName = ''
        if ($match) {
            $health = switch ([int](Get-TrdWmiValue $match 'HealthStatus' -Default -1)) {
                0 { '健康' } 1 { '警告' } 2 { '不健康' } 5 { '未知' } default { $null }
            }
            if (-not $media) {
                $media = switch ([int](Get-TrdWmiValue $match 'MediaType' -Default 0)) {
                    3 { '硬盘 (HDD)' } 4 { '固态硬盘 (SSD)' } 5 { 'SCM' } default { '' }
                }
            }
            try {
                $bus = [int](Get-TrdWmiValue $match 'BusType' -Default 0)
                $busName = switch ($bus) {
                    1 { 'SCSI' } 2 { 'ATAPI' } 3 { 'ATA' } 4 { 'IEEE1394' } 5 { 'SSA' }
                    6 { '光纤' } 7 { 'USB' } 8 { 'RAID' } 9 { 'iSCSI' } 10 { 'SAS' }
                    11 { 'SATA' } 12 { 'SD' } 13 { 'MMC' } 17 { 'NVMe' } default { '' }
                }
            } catch { }
        }

        # 接口显示：MSFT 的 BusType 比 Win32_DiskDrive.InterfaceType 精确得多。
        # NVMe 固态盘在 Win32 里经常被报成 "SCSI"，只显示它会产生误导。
        # 两者都有且不同时，把 Win32 的值放进括号保留原始信息。
        $ifaceWin = [string](Get-TrdWmiValue $d 'InterfaceType')
        $iface = if ($busName) {
            if ($ifaceWin -and $ifaceWin -ne $busName) { "$busName（$ifaceWin）" } else { $busName }
        } else { $ifaceWin }

        $null = $diskList.Add([PSCustomObject]@{
            Index        = [int](Get-TrdWmiValue $d 'Index' -Default -1)
            Model        = ([string](Get-TrdWmiValue $d 'Model')).Trim()
            Serial       = $serial
            Interface    = $iface
            MediaType    = $media
            Health       = $health
            SizeGB       = $sizeGB
            Partitions   = [int](Get-TrdWmiValue $d 'Partitions' -Default 0)
            Firmware     = ([string](Get-TrdWmiValue $d 'FirmwareRevision')).Trim()
            Status       = [string](Get-TrdWmiValue $d 'Status')
        })
    }

    $volList = New-Object System.Collections.ArrayList
    foreach ($v in $vols) {
        if (-not $v) { continue }
        $dt = [int](Get-TrdWmiValue $v 'DriveType' -Default 0)
        if ($dt -eq 5 -and -not (Get-TrdWmiValue $v 'Size')) { continue }   # 跳过空光驱
        $totalGB = 0; $freeGB = 0
        try { $totalGB = [Math]::Round([double](Get-TrdWmiValue $v 'Size') / 1GB, 1) } catch { }
        try { $freeGB  = [Math]::Round([double](Get-TrdWmiValue $v 'FreeSpace') / 1GB, 1) } catch { }
        $usedPct = if ($totalGB -gt 0) { [Math]::Round((($totalGB - $freeGB) / $totalGB) * 100, 0) } else { 0 }

        $null = $volList.Add([PSCustomObject]@{
            Drive        = [string](Get-TrdWmiValue $v 'DeviceID')
            Label        = [string](Get-TrdWmiValue $v 'VolumeName')
            FileSystem   = [string](Get-TrdWmiValue $v 'FileSystem')
            DriveType    = $(switch ($dt) { 2 { '可移动' } 3 { '本地磁盘' } 4 { '网络' } 5 { '光驱' } 6 { 'RAM 盘' } default { "类型$dt" } })
            TotalGB      = $totalGB
            FreeGB       = $freeGB
            UsedPercent  = $usedPct
            Serial       = ([string](Get-TrdWmiValue $v 'VolumeSerialNumber')).Trim()
        })
    }

    return [PSCustomObject]@{
        Disks    = @($diskList)
        Volumes  = @($volList)
        Partitions = @($parts | Where-Object { $_ } | ForEach-Object {
            [PSCustomObject]@{
                Name    = [string](Get-TrdWmiValue $_ 'Name')
                Type    = [string](Get-TrdWmiValue $_ 'Type')
                SizeGB  = $(try { [Math]::Round([double](Get-TrdWmiValue $_ 'Size') / 1GB, 1) } catch { 0 })
                Bootable = [bool](Get-TrdWmiValue $_ 'Bootable')
            }
        })
    }
}

# ---------------------------------------------------------------------------
#  网络
# ---------------------------------------------------------------------------
function Get-TrdSysNetwork {
    $adapters = @(Get-TrdWmiList 'Win32_NetworkAdapter')
    $cfgs     = @(Get-TrdWmiList 'Win32_NetworkAdapterConfiguration')

    $cfgByIndex = @{}
    foreach ($c in $cfgs) { if ($c) { $cfgByIndex[[string](Get-TrdWmiValue $c 'Index')] = $c } }

    $out = New-Object System.Collections.ArrayList
    foreach ($a in $adapters) {
        if (-not $a) { continue }
        # 只列物理网卡，跳过 WAN Miniport / 隧道适配器这类虚拟项
        $phys = $true
        try { $phys = [bool](Get-TrdWmiValue $a 'PhysicalAdapter') } catch { }
        $name = [string](Get-TrdWmiValue $a 'Name')
        if (-not $phys -and $name -match 'WAN Miniport|Tunnel|隧道|Kernel Debug|Virtual|Loopback|环回') { continue }

        $idx = [string](Get-TrdWmiValue $a 'Index')
        $cfg = if ($cfgByIndex.ContainsKey($idx)) { $cfgByIndex[$idx] } else { $null }

        $ips = @()
        if ($cfg) { $ips = @(Get-TrdWmiValue $cfg 'IPAddress' | Where-Object { $_ }) }
        $gws = @()
        if ($cfg) { $gws = @(Get-TrdWmiValue $cfg 'DefaultIPGateway' | Where-Object { $_ }) }
        $dns = @()
        if ($cfg) { $dns = @(Get-TrdWmiValue $cfg 'DNSServerSearchOrder' | Where-Object { $_ }) }

        $speedMbps = 0
        try { $speedMbps = [Math]::Round([double](Get-TrdWmiValue $a 'Speed' -Default 0) / 1MB, 0) } catch { }

        $null = $out.Add([PSCustomObject]@{
            Name        = $name
            Description = [string](Get-TrdWmiValue $a 'Description')
            MAC         = [string](Get-TrdWmiValue $a 'MACAddress')
            Type        = $(switch ([int](Get-TrdWmiValue $a 'AdapterTypeID' -Default -1)) {
                            0 { '以太网' } 1 { '令牌环' } 2 { 'FDDI' } 9 { '无线 (802.11)' }
                            default { [string](Get-TrdWmiValue $a 'AdapterType') } })
            Physical    = $phys
            SpeedMbps   = $speedMbps
            NetEnabled  = $(try { [bool](Get-TrdWmiValue $a 'NetEnabled') } catch { $null })
            NetConnectionStatus = $(switch ([int](Get-TrdWmiValue $a 'NetConnectionStatus' -Default 0)) {
                            0 { '断开' } 1 { '正在连接' } 2 { '已连接' } 3 { '正在断开' }
                            4 { '硬件不存在' } 5 { '硬件已禁用' } 6 { '硬件故障' } 7 { '媒体已断开' }
                            8 { '正在验证身份' } 9 { '身份验证成功' } 10 { '身份验证失败' }
                            11 { '地址无效' } 12 { '需要凭据' } default { '未知' } })
            IPAddresses = $ips
            Gateways    = $gws
            DnsServers  = $dns
            DhcpEnabled = $(try { [bool](Get-TrdWmiValue $cfg 'DHCPEnabled') } catch { $null })
            DriverVersion = ([string](Get-TrdWmiValue $a 'DriverVersion' -Default '')).Trim()
            Status      = [string](Get-TrdWmiValue $a 'Status')
        })
    }
    return @($out)
}

# ---------------------------------------------------------------------------
#  问题设备（ConfigManagerErrorCode != 0）
# ---------------------------------------------------------------------------
function Get-TrdSysPnpSnapshot {
    <#
    .SYNOPSIS
        一次性取回全部 PnP 设备，供"问题设备"与"USB 设备"共用。
    .DESCRIPTION
        Win32_PnPEntity 通常有几百个条目，查询一次就好。
        两次查询在慢机器上会白白多花好几秒。
    #>
    return @(Get-TrdWmiList 'Win32_PnPEntity')
}

function Get-TrdSysProblemDevices {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()]$PnpEntities)

    $out = New-Object System.Collections.ArrayList
    foreach ($e in $PnpEntities) {
        if (-not $e) { continue }
        $code = 0
        try { $code = [int](Get-TrdWmiValue $e 'ConfigManagerErrorCode' -Default 0) } catch { }
        if ($code -eq 0) { continue }

        $meaning = if ($script:TRD_CM_ERROR.ContainsKey($code)) { $script:TRD_CM_ERROR[$code] } else { "未知错误码 $code" }
        $null = $out.Add([PSCustomObject]@{
            Name      = [string](Get-TrdWmiValue $e 'Name')
            Class     = [string](Get-TrdWmiValue $e 'PNPClass')
            ErrorCode = $code
            Meaning   = $meaning
            DeviceID  = [string](Get-TrdWmiValue $e 'DeviceID')
            Status    = [string](Get-TrdWmiValue $e 'Status')
        })
    }
    return @($out | Sort-Object ErrorCode, Name)
}

function Get-TrdSysUsbDevices {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()]$PnpEntities)

    $out = New-Object System.Collections.ArrayList
    foreach ($e in $PnpEntities) {
        if (-not $e) { continue }
        $id = [string](Get-TrdWmiValue $e 'DeviceID')
        if ($id -notlike 'USB\*') { continue }
        $null = $out.Add([PSCustomObject]@{
            Name         = [string](Get-TrdWmiValue $e 'Name')
            Class        = [string](Get-TrdWmiValue $e 'PNPClass')
            Manufacturer = [string](Get-TrdWmiValue $e 'Manufacturer')
            Status       = [string](Get-TrdWmiValue $e 'Status')
            ErrorCode    = [int](Get-TrdWmiValue $e 'ConfigManagerErrorCode' -Default 0)
        })
    }
    return @($out | Sort-Object Class, Name)
}

# ---------------------------------------------------------------------------
#  输入设备 / 电源 / 热
# ---------------------------------------------------------------------------
function Get-TrdSysInputDevices {
    $kb = @(Get-TrdWmiList 'Win32_Keyboard')
    $pt = @(Get-TrdWmiList 'Win32_PointingDevice')
    $out = [PSCustomObject]@{ Keyboards = @(); Pointing = @() }

    $out.Keyboards = @($kb | Where-Object { $_ } | ForEach-Object {
        [PSCustomObject]@{
            Name = [string](Get-TrdWmiValue $_ 'Name')
            Description = [string](Get-TrdWmiValue $_ 'Description')
            Layout = [string](Get-TrdWmiValue $_ 'Layout')
            Status = [string](Get-TrdWmiValue $_ 'Status')
        }
    })
    $out.Pointing = @($pt | Where-Object { $_ } | ForEach-Object {
        [PSCustomObject]@{
            Name = [string](Get-TrdWmiValue $_ 'Name')
            Description = [string](Get-TrdWmiValue $_ 'Description')
            Type = $(switch ([int](Get-TrdWmiValue $_ 'PointingType' -Default 0)) {
                        1 { '其他' } 2 { '未知' } 3 { '鼠标' } 4 { '轨迹球' }
                        5 { '轨迹点' } 6 { '触摸板' } 7 { '触摸屏' } 8 { '手写笔' } default { '' } })
            Status = [string](Get-TrdWmiValue $_ 'Status')
        }
    })
    return $out
}

function Get-TrdSysPower {
    $bat = @(Get-TrdWmiList 'Win32_Battery')
    $bats = New-Object System.Collections.ArrayList
    foreach ($b in $bat) {
        if (-not $b) { continue }
        $null = $bats.Add([PSCustomObject]@{
            Name         = [string](Get-TrdWmiValue $b 'Name')
            Chemistry    = $(switch ([int](Get-TrdWmiValue $b 'Chemistry' -Default 0)) {
                                1 { '其他' } 2 { '未知' } 3 { '铅酸' } 4 { '镍镉' }
                                5 { '镍氢' } 6 { '锂离子' } 7 { '锌空气' } 8 { '锂聚合物' } default { '' } })
            EstimatedChargePercent = [int](Get-TrdWmiValue $b 'EstimatedChargeRemaining' -Default 0)
            DesignCapacity = [int](Get-TrdWmiValue $b 'DesignCapacity' -Default 0)
            FullChargeCapacity = [int](Get-TrdWmiValue $b 'FullChargeCapacity' -Default 0)
            Status       = [string](Get-TrdWmiValue $b 'Status')
        })
    }

    # 电源计划：powercfg 是只读查询，任何 Windows 都自带
    $plan = $null
    try {
        $raw = & "$env:windir\System32\powercfg.exe" /getactivescheme 2>$null
        if ($raw) {
            $s = [string]($raw | Select-Object -First 1)
            if ($s -match '\((.+)\)') { $plan = $Matches[1].Trim() }
            elseif ($s -match ':\s*(.+)$') { $plan = $Matches[1].Trim() }
        }
    } catch { }

    return [PSCustomObject]@{ Batteries = @($bats); ActivePlan = $plan }
}

function Get-TrdSysThermal {
    $t = @(Get-TrdWmiList 'Win32_TemperatureProbe')
    $f = @(Get-TrdWmiList 'Win32_Fan')
    # MSAcpi_ThermalZoneTemperature 在多数消费级主板上需要管理员且常返回不支持
    $zone = @(Get-TrdWmiList -ClassName 'MSAcpi_ThermalZoneTemperature' -Namespace 'root\wmi')

    $zones = New-Object System.Collections.ArrayList
    foreach ($z in $zone) {
        if (-not $z) { continue }
        $c = $null
        try {
            $tenths = [double](Get-TrdWmiValue $z 'CurrentTemperature' -Default 0)
            if ($tenths -gt 0) { $c = [Math]::Round(($tenths / 10.0) - 273.15, 1) }
        } catch { }
        $null = $zones.Add([PSCustomObject]@{
            Zone = [string](Get-TrdWmiValue $z 'InstanceName')
            Celsius = $c
        })
    }

    return [PSCustomObject]@{
        Probes  = @($t | Where-Object { $_ } | ForEach-Object { [PSCustomObject]@{ Name = [string](Get-TrdWmiValue $_ 'Name'); Status = [string](Get-TrdWmiValue $_ 'Status') } })
        Fans    = @($f | Where-Object { $_ } | ForEach-Object { [PSCustomObject]@{ Name = [string](Get-TrdWmiValue $_ 'Name'); Status = [string](Get-TrdWmiValue $_ 'Status'); DesiredSpeed = [int](Get-TrdWmiValue $_ 'DesiredSpeed' -Default 0) } })
        Zones   = @($zones)
    }
}

# ---------------------------------------------------------------------------
#  补丁 / 启动项 / 关键服务 / 运行库
# ---------------------------------------------------------------------------
function Get-TrdSysHotfixes {
    $hf = @(Get-TrdWmiList 'Win32_QuickFixEngineering')
    return @($hf | Where-Object { $_ } | ForEach-Object {
        $d = $null
        try {
            $raw = Get-TrdWmiValue $_ 'InstalledOn'
            if ($raw) { $d = $raw }
        } catch { }
        [PSCustomObject]@{
            HotFixID    = [string](Get-TrdWmiValue $_ 'HotFixID')
            Description = [string](Get-TrdWmiValue $_ 'Description')
            InstalledOn = $d
            InstalledBy = [string](Get-TrdWmiValue $_ 'InstalledBy')
        }
    } | Sort-Object HotFixID)
}

function Get-TrdSysStartupItems {
    $sc = @(Get-TrdWmiList 'Win32_StartupCommand')
    return @($sc | Where-Object { $_ } | ForEach-Object {
        [PSCustomObject]@{
            Name     = [string](Get-TrdWmiValue $_ 'Name')
            Command  = [string](Get-TrdWmiValue $_ 'Command')
            Location = [string](Get-TrdWmiValue $_ 'Location')
            User     = [string](Get-TrdWmiValue $_ 'User')
        }
    })
}

function Get-TrdSysKeyServices {
    <#
    .SYNOPSIS
        检查与游戏/运行库安装相关的关键服务。
    .DESCRIPTION
        注意"已停止"与"被禁用"是两回事：
        msiserver、TrustedInstaller 平时就是停止的（手动触发），
        只有启动类型为 Disabled 才是故障。
    #>
    $names = @(
        @{ N = 'Audiosrv';              D = 'Windows Audio（DirectSound 依赖）'; StoppedIsBad = $true }
        @{ N = 'AudioEndpointBuilder';  D = '音频终结点生成器';                   StoppedIsBad = $true }
        @{ N = 'msiserver';             D = 'Windows Installer（安装运行库）';    StoppedIsBad = $false }
        @{ N = 'TrustedInstaller';      D = 'Windows Modules Installer';          StoppedIsBad = $false }
        @{ N = 'Themes';                D = '主题（DWM/Aero 相关）';              StoppedIsBad = $true }
        @{ N = 'Dnscache';              D = 'DNS 客户端';                         StoppedIsBad = $true }
        @{ N = 'EventLog';              D = 'Windows 事件日志';                   StoppedIsBad = $true }
        @{ N = 'Winmgmt';               D = 'WMI 服务（本工具依赖）';             StoppedIsBad = $true }
    )
    $out = New-Object System.Collections.ArrayList
    foreach ($s in $names) {
        $st = $null; $startType = $null
        try {
            $svc = Get-Service -Name $s.N -ErrorAction Stop
            $st = [string]$svc.Status
            $startType = [string]$svc.StartType
        } catch { }
        $null = $out.Add([PSCustomObject]@{
            Name        = $s.N
            Display     = $s.D
            Status      = $st
            StartType   = $startType
            Problem     = $(if ($null -eq $st) { $null }
                            elseif ($startType -eq 'Disabled') { $true }
                            elseif ($s.StoppedIsBad -and $st -ne 'Running') { $true }
                            else { $false })
        })
    }
    return @($out)
}

function Get-TrdSysRuntimes {
    $dirX86 = Get-TrdSystemDir -Bitness 'x86'
    $dirX64 = Get-TrdSystemDir -Bitness 'x64'

    $probe = @('d3d8.dll','d3d9.dll','d3dx9_43.dll','d3dx9_36.dll','D3DCompiler_43.dll','XAudio2_7.dll','xinput1_3.dll','ddraw.dll')
    $dx86 = @(); $dx64 = @()
    foreach ($n in $probe) {
        if ($dirX86 -and (Test-Path -LiteralPath (Join-Path $dirX86 $n))) { $dx86 += $n }
        if ($dirX64 -and (Test-Path -LiteralPath (Join-Path $dirX64 $n))) { $dx64 += $n }
    }

    $vc = @()
    try { $vc = @(Get-TrdVcRuntimeState) } catch { }
    $net = $null
    try { $net = Get-TrdDotNetState } catch { }

    return [PSCustomObject]@{
        DirX86    = $dirX86
        DirX64    = $dirX64
        DxX86     = @($dx86)
        DxX64     = @($dx64)
        Vc        = @($vc)
        DotNet    = $net
        DirectXReg = $(try { (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\DirectX' -Name Version -ErrorAction Stop).Version } catch { $null })
    }
}

# ---------------------------------------------------------------------------
#  总入口
# ---------------------------------------------------------------------------
function Get-TrdDeviceInfo {
    <#
    .SYNOPSIS
        采齐全机设备与系统信息，返回一棵可直接渲染的对象树。
    .PARAMETER OnProgress
        进度回调，参数为 (步骤序号, 总步数, 说明)。用于在控制台显示进度。
    #>
    [CmdletBinding()]
    param([scriptblock]$OnProgress)

    $steps = @(
        '系统与主板', '操作系统', '处理器', '内存', '显卡与显示模式',
        '显示器 (EDID)', '存储设备', '音频设备', '网络适配器',
        '即插即用设备', '输入设备', '电源与电池', '温度与风扇',
        '系统补丁', '启动项', '关键服务', '运行库'
    )
    $total = $steps.Count
    # 进度计数器必须放在一个引用类型里。
    # 如果写成 $i = 0 然后让 scriptblock 里的 $i++ 去改，PowerShell 会用
    # & 调用 scriptblock 时新建作用域，$i++ 改的只是【副本】，父作用域的 $i
    # 永远是 0 —— 表现就是所有步骤都显示 0%/6%。
    $counter = [PSCustomObject]@{ N = 0 }
    $report = {
        param([string]$msg)
        $counter.N++
        if ($OnProgress) { & $OnProgress $counter.N $total $msg }
    }

    & $report '系统与主板'
    $identity = Get-TrdSysIdentity

    & $report '操作系统'
    $osInfo = Get-TrdSysOsInfo

    & $report '处理器'
    # 必须用 @() 包住：函数返回单元素数组时 PowerShell 会解包成标量，
    # 之后 $Info.CPU.Count 就会抛 PropertyNotFoundException。
    $cpu = @(Get-TrdSysCpu)

    & $report '内存'
    $mem = Get-TrdSysMemory

    & $report '显卡与显示模式'
    $gpu = @()
    try { $gpu = @(Get-TrdGpuState) } catch { }
    $modes = $null
    try { $modes = Get-TrdDisplayModes } catch { }

    & $report '显示器 (EDID)'
    $monitors = @()
    try { $monitors = @(Get-TrdSysMonitors) } catch { }

    & $report '存储设备'
    $storage = $null
    try { $storage = Get-TrdSysStorage } catch { }

    & $report '音频设备'
    $audio = $null
    try { $audio = Get-TrdAudioState } catch { }

    & $report '网络适配器'
    $net = @()
    try { $net = @(Get-TrdSysNetwork) } catch { }

    & $report '即插即用设备'
    $pnp = @()
    try { $pnp = @(Get-TrdSysPnpSnapshot) } catch { }
    $problems = @()
    $usb = @()
    try { $problems = @(Get-TrdSysProblemDevices -PnpEntities $pnp) } catch { }
    try { $usb = @(Get-TrdSysUsbDevices -PnpEntities $pnp) } catch { }

    & $report '输入设备'
    $input = $null
    try { $input = Get-TrdSysInputDevices } catch { }

    & $report '电源与电池'
    $power = $null
    try { $power = Get-TrdSysPower } catch { }

    & $report '温度与风扇'
    $thermal = $null
    try { $thermal = Get-TrdSysThermal } catch { }

    & $report '系统补丁'
    $hotfix = @()
    try { $hotfix = @(Get-TrdSysHotfixes) } catch { }

    & $report '启动项'
    $startup = @()
    try { $startup = @(Get-TrdSysStartupItems) } catch { }

    & $report '关键服务'
    $services = @()
    try { $services = @(Get-TrdSysKeyServices) } catch { }

    & $report '运行库'
    $runtimes = $null
    try { $runtimes = Get-TrdSysRuntimes } catch { }

    $sec = $null
    try { $sec = Get-TrdSecurityProducts } catch { }
    $conflicts = @()
    try { $conflicts = @(Get-TrdConflictProcessesSafe) } catch { }

    return [PSCustomObject]@{
        Meta = [PSCustomObject]@{
            Tool        = 'Touhou Runtime Doctor - 设备信息采集'
            Version     = $(if ($script:TRD.ToolVersion) { $script:TRD.ToolVersion } else { '未知' })
            CollectedAt = (Get-Date)
            IsAdmin     = [bool]$script:TRD.IsAdmin
            Is64OS      = [bool]$script:TRD.Is64OS
            PsVersion   = [string]$PSVersionTable.PSVersion
            PsEdition   = [string]$script:TRD.PSEdition
            ToolRoot    = [string]$script:TRD.ToolRoot
        }
        Identity  = $identity
        OS        = $osInfo
        CPU       = $cpu
        Memory    = $mem
        Graphics  = $gpu
        DisplayModes = $modes
        Monitors  = $monitors
        Storage   = $storage
        Audio     = $audio
        Network   = $net
        ProblemDevices = $problems
        UsbDevices = $usb
        Input     = $input
        Power     = $power
        Thermal   = $thermal
        Hotfixes  = $hotfix
        Startup   = $startup
        Services  = $services
        Runtimes  = $runtimes
        Security  = $sec
        Conflicts = $conflicts
    }
}

function Get-TrdConflictProcessesSafe {
    # Get-TrdConflictingProcesses 定义在 Detect.ps1；单独加载本文件时可能不存在
    if (Get-Command -Name 'Get-TrdConflictingProcesses' -ErrorAction SilentlyContinue) {
        return @(Get-TrdConflictingProcesses)
    }
    return @()
}
