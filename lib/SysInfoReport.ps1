# ============================================================================
#  SysInfoReport.ps1 -- 设备信息渲染
#
#  输出四种格式，各有明确用途：
#   * 设备信息.txt     -- GBK 编码，记事本直接可读，适合自己看/打印
#   * 设备信息.html     -- 带表格与配色，适合快速扫读、截图
#   * 设备信息.json     -- 机器可读，适合跨机器对比或二次处理
#   * 设备信息-精简.txt  -- 一屏以内的摘要，适合发到论坛/群里求助
#
#  JSON 特意把 \uXXXX 还原成原字符：PowerShell 5.1 的 ConvertTo-Json 会把所有
#  非 ASCII 字符转义，导出的文件人根本没法看，而排查问题时又常常需要人肉读它。
# ============================================================================
Set-StrictMode -Version 2.0

function Get-TrdSafeGbk {
    param([string]$Text)
    if (Get-Command -Name 'ConvertTo-TrdGbkSafe' -ErrorAction SilentlyContinue) {
        return (ConvertTo-TrdGbkSafe -Text $Text)
    }
    return $Text
}

function Get-TrdSafeHtml {
    param([string]$Text)
    if (Get-Command -Name 'ConvertTo-TrdHtmlSafe' -ErrorAction SilentlyContinue) {
        return (ConvertTo-TrdHtmlSafe -Text $Text)
    }
    if ($null -eq $Text) { return '' }
    return ($Text -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;' -replace '"', '&quot;')
}

function Format-TrdSizeGB {
    param($GB)
    if ($null -eq $GB) { return '-' }
    if ([double]$GB -ge 1024) { return ('{0:N2} TB' -f ([double]$GB / 1024)) }
    return ('{0:N1} GB' -f [double]$GB)
}

function Format-TrdUptime {
    param($Span)
    if ($null -eq $Span) { return '-' }
    $d = $Span.Days; $h = $Span.Hours; $m = $Span.Minutes
    if ($d -gt 0) { return "$d 天 $h 小时 $m 分" }
    if ($h -gt 0) { return "$h 小时 $m 分" }
    return "$m 分"
}

# ---------------------------------------------------------------------------
#  文本报告
# ---------------------------------------------------------------------------
function New-TrdSysInfoText {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Info)

    $L = New-Object System.Collections.ArrayList
    $add  = { param([string]$s) $null = $L.Add($s) }
    $line = '=' * 78
    $sub  = '-' * 78

    $sec = {
        param([string]$title)
        & $add ''
        & $add $sub
        & $add "  $title"
        & $add $sub
    }
    $kv = { param([string]$k, $v)
        $val = if ($null -eq $v -or "$v" -eq '') { '-' } else { "$v" }
        & $add ("  {0,-22}: {1}" -f $k, $val)
    }

    & $add $line
    & $add '  设备与系统信息报告'
    & $add '  Touhou Runtime Doctor'
    & $add $line
    & $add ''
    & $kv '采集时间' $Info.Meta.CollectedAt.ToString('yyyy-MM-dd HH:mm:ss')
    & $kv '工具版本' $Info.Meta.Version
    & $kv '管理员权限' $(if ($Info.Meta.IsAdmin) { '是' } else { '否（部分信息可能不完整）' })
    & $kv 'PowerShell' "$($Info.Meta.PsVersion) ($($Info.Meta.PsEdition))"
    & $kv '系统位数' $(if ($Info.Meta.Is64OS) { '64 位' } else { '32 位' })

    # ---------------- 概览 ----------------
    & $sec '系统概览'
    & $kv '计算机名' $Info.Identity.ComputerName
    & $kv '制造商 / 型号' "$($Info.Identity.Manufacturer) $($Info.Identity.Model)".Trim()
    & $kv '机箱类型' $Info.Identity.ChassisType
    & $kv '产品名称' $Info.Identity.ProductName
    & $kv '序列号' $Info.Identity.IdentifyingNum
    & $kv '系统类型' $Info.Identity.SystemType
    & $kv '工作组 / 域' $(if ($Info.Identity.Domain) { $Info.Identity.Domain } else { $Info.Identity.Workgroup })
    & $kv '当前用户' $Info.Identity.LoggedUser

    # ---------------- 操作系统 ----------------
    & $sec '操作系统'
    & $kv '版本' $Info.OS.Caption
    & $kv '内部版本' "$($Info.OS.Version) (Build $($Info.OS.Build))"
    & $kv '体系结构' $Info.OS.Architecture
    & $kv 'Service Pack' $Info.OS.ServicePack
    & $kv '安装日期' $(if ($Info.OS.InstallDate) { $Info.OS.InstallDate.ToString('yyyy-MM-dd') } else { '-' })
    & $kv '上次启动' $(if ($Info.OS.LastBoot) { $Info.OS.LastBoot.ToString('yyyy-MM-dd HH:mm:ss') } else { '-' })
    & $kv '已运行' (Format-TrdUptime $Info.OS.Uptime)
    & $kv '系统区域' "$($Info.OS.SystemLocale)（代码页 $($Info.OS.AcpCodePage)）"
    & $kv '时区' $Info.OS.TimeZone
    & $kv '系统盘' $Info.OS.SystemDrive
    & $kv '物理内存' "$($Info.OS.TotalMemMB) MB（可用 $($Info.OS.FreeMemMB) MB）"
    & $kv '虚拟内存' "$($Info.OS.TotalVirtMB) MB（可用 $($Info.OS.FreeVirtMB) MB）"

    # ---------------- 主板 / BIOS ----------------
    & $sec '主板与 BIOS'
    & $kv '主板' "$($Info.Identity.BoardVendor) $($Info.Identity.BoardProduct)".Trim()
    & $kv '主板版本' $Info.Identity.BoardVersion
    & $kv 'BIOS 厂商' $Info.Identity.BiosVendor
    & $kv 'BIOS 版本' $Info.Identity.BiosVersion
    & $kv 'BIOS 日期' $(if ($Info.Identity.BiosDate) { $Info.Identity.BiosDate.ToString('yyyy-MM-dd') } else { '-' })
    & $kv '引导模式' $Info.Identity.BiosMode
    & $kv '安全启动' $(if ($null -eq $Info.Identity.SecureBoot) { '不适用' } elseif ($Info.Identity.SecureBoot) { '已启用' } else { '已关闭' })

    # ---------------- CPU ----------------
    & $sec '处理器'
    $ci = 0
    foreach ($c in $Info.CPU) {
        $ci++
        if ($Info.CPU.Count -gt 1) { & $add "  [处理器 $ci]" }
        & $kv '型号' $c.Name
        & $kv '架构' $c.Architecture
        & $kv '核心 / 线程' "$($c.Cores) 核 / $($c.Threads) 线程"
        & $kv '频率' "$($c.CurClockMHz) MHz（最高 $($c.MaxClockMHz) MHz）"
        & $kv '插槽' $c.SocketDesignation
        & $kv '二级 / 三级缓存' "$($c.L2CacheKB) KB / $($c.L3CacheKB) KB"
        & $kv '硬件虚拟化' $(if ($null -eq $c.Virtualization) { '未知' } elseif ($c.Virtualization) { '已启用' } else { '未启用' })
        if ($c.Caches -and $c.Caches.Count -gt 0) {
            & $add ("  {0,-22}: {1}" -f '缓存明细', (($c.Caches | ForEach-Object { "$($_.Level) $($_.Type) $($_.SizeKB)KB" }) -join ' | '))
        }
    }

    # ---------------- 内存 ----------------
    & $sec '内存'
    & $kv '总容量' "$($Info.Memory.InstalledGB) GB"
    & $kv '插槽使用' "$($Info.Memory.UsedSlots) / $($Info.Memory.SlotCount)"
    & $kv '频率' $Info.Memory.SpeedSummary
    if ($Info.Memory.Slots.Count -gt 0) {
        & $add ''
        & $add ('  {0,-6} {1,-10} {2,-8} {3,-10} {4,-22} {5}' -f '插槽', '容量', '频率', '类型', '厂商', '型号')
        & $add ('  ' + ('-' * 90))
        foreach ($s in $Info.Memory.Slots) {
            & $add ('  {0,-6} {1,-10} {2,-8} {3,-10} {4,-22} {5}' -f `
                $s.DeviceLocator, "$($s.CapacityGB)GB", "$($s.SpeedMHz)MHz", $s.MemoryType, $s.Manufacturer, $s.PartNumber)
        }
    }
    if ($Info.Memory.PageFiles.Count -gt 0) {
        & $add ''
        foreach ($p in $Info.Memory.PageFiles) {
            & $add ("  {0,-22}: {1} MB（当前使用 $($p.CurrentMB) MB，峰值 $($p.PeakMB) MB）" -f '页面文件', $p.AllocMB)
        }
    }

    # ---------------- 显卡 ----------------
    & $sec '显卡与显示'
    if ($Info.Graphics.Count -eq 0) {
        & $add '  （未检测到显示适配器）'
    }
    foreach ($g in $Info.Graphics) {
        & $kv '显示适配器' $g.Name
        & $kv '厂商 / 处理器' "$($g.Vendor) / $($g.VideoProcessor)".Trim(' ', '/')
        & $kv '显存' $(if ($null -ne $g.AdapterRAM_MB) { "$($g.AdapterRAM_MB) MB" } else { '未知' })
        & $kv '驱动版本' $g.DriverVersion
        & $kv '驱动日期' $(if ($g.DriverDate) { $g.DriverDate.ToString('yyyy-MM-dd') } else { '未知' })
        & $kv '驱动年龄' $(if ($g.DriverAgeYears) { "$($g.DriverAgeYears) 年" } else { '未知' })
        # 子表达式必须写在一行内：PowerShell 的普通双引号字符串不能跨行
        $errText = if ($script:TRD_CM_ERROR -and $script:TRD_CM_ERROR.ContainsKey($g.ErrorCode)) { $script:TRD_CM_ERROR[$g.ErrorCode] } else { '-' }
        & $kv '设备状态' "$($g.Status)（错误码 $($g.ErrorCode)：$errText）"
        & $kv '当前模式' "$($g.CurWidth)x$($g.CurHeight) @ $($g.CurRefresh)Hz"
        if ($g.IsBasicAdapter) {
            & $add '  ★ 警告：当前使用 Windows 自带兜底显示驱动，没有 3D 加速能力。'
        }
    }
    if ($Info.DisplayModes -and $Info.DisplayModes.Detected) {
        & $add ''
        & $kv '显示模式数' $Info.DisplayModes.ModeCount
        & $kv '是否含 640x480' $(if ($Info.DisplayModes.Has640x480) { '是' } else { '否（老游戏全屏可能失败）' })
        & $kv '是否含 800x600' $(if ($Info.DisplayModes.Has800x600) { '是' } else { '否' })
        & $kv '最小模式' "$($Info.DisplayModes.MinWidth)x$($Info.DisplayModes.MinHeight)"
    }

    # ---------------- 显示器 ----------------
    if ($Info.Monitors.Count -gt 0) {
        & $sec '显示器'
        foreach ($m in $Info.Monitors) {
            $name = if ($m.Name) { $m.Name } else { '(未提供名称)' }
            & $kv '显示器' "$name  厂商:$($m.Vendor)  产品码:$($m.ProductCode)"
            if ($m.DiagonalInch) { & $kv '物理尺寸' "$($m.WidthCm) x $($m.HeightCm) cm（约 $($m.DiagonalInch) 英寸）" }
            if ($m.Year) { & $kv '生产日期' "$($m.Year) 年第 $($m.Week) 周" }
            if ($m.Connection) { & $kv '连接方式' $m.Connection }
        }
    }

    # ---------------- 存储 ----------------
    if ($Info.Storage) {
        & $sec '存储设备'
        if ($Info.Storage.Disks.Count -gt 0) {
            & $add ('  {0,-6} {1,-34} {2,-12} {3,-10} {4,-8} {5}' -f '编号', '型号', '容量', '接口', '介质', '健康')
            & $add ('  ' + ('-' * 90))
            foreach ($d in $Info.Storage.Disks) {
                & $add ('  {0,-6} {1,-34} {2,-12} {3,-10} {4,-8} {5}' -f `
                    $d.Index, $d.Model, (Format-TrdSizeGB $d.SizeGB), $d.Interface, $d.MediaType, $(if ($d.Health) { $d.Health } else { '-' }))
            }
        }
        & $add ''
        & $add ('  {0,-6} {1,-14} {2,-10} {3,-12} {4,-12} {5}' -f '盘符', '卷标', '文件系统', '总容量', '可用', '已用')
        & $add ('  ' + ('-' * 90))
        foreach ($v in $Info.Storage.Volumes) {
            & $add ('  {0,-6} {1,-14} {2,-10} {3,-12} {4,-12} {5}' -f `
                $v.Drive, $v.Label, $v.FileSystem, (Format-TrdSizeGB $v.TotalGB), (Format-TrdSizeGB $v.FreeGB), "$($v.UsedPercent)%")
        }
    }

    # ---------------- 音频 ----------------
    if ($Info.Audio) {
        & $sec '音频设备'
        & $kv 'Windows Audio 服务' "$($Info.Audio.ServiceStatus)（启动类型 $($Info.Audio.ServiceStart)）"
        & $kv '设备数量' $Info.Audio.DeviceCount
        foreach ($d in $Info.Audio.Devices) {
            & $add ("  {0,-22}: {1}  [{2}]" -f '设备', $d.Name, $d.Status)
        }
    }

    # ---------------- 网络 ----------------
    if ($Info.Network.Count -gt 0) {
        & $sec '网络适配器'
        foreach ($n in $Info.Network) {
            & $add "  [$($n.Name)]"
            & $add ("      {0,-16}: {1}" -f '类型 / 状态', "$($n.Type) / $($n.NetConnectionStatus)")
            if ($n.MAC)        { & $add ("      {0,-16}: {1}" -f 'MAC 地址', $n.MAC) }
            if ($n.IPAddresses.Count -gt 0) { & $add ("      {0,-16}: {1}" -f 'IP 地址', ($n.IPAddresses -join ', ')) }
            if ($n.Gateways.Count -gt 0)    { & $add ("      {0,-16}: {1}" -f '网关', ($n.Gateways -join ', ')) }
            if ($n.DnsServers.Count -gt 0)  { & $add ("      {0,-16}: {1}" -f 'DNS', ($n.DnsServers -join ', ')) }
            if ($n.SpeedMbps)  { & $add ("      {0,-16}: {1}" -f '链路速率', "$($n.SpeedMbps) Mbps") }
            if ($n.DriverVersion) { & $add ("      {0,-16}: {1}" -f '驱动版本', $n.DriverVersion) }
        }
    }

    # ---------------- 问题设备（重点） ----------------
    & $sec '有问题的设备（驱动异常清单）'
    if ($Info.ProblemDevices.Count -eq 0) {
        & $add '  未发现任何状态异常的设备。这是好消息。'
    } else {
        & $add "  共 $($Info.ProblemDevices.Count) 个设备报告了问题："
        & $add ''
        foreach ($p in $Info.ProblemDevices) {
            & $add "  * $($p.Name)  [$($p.Class)]"
            & $add "      错误码 $($p.ErrorCode)：$($p.Meaning)"
            & $add "      设备 ID：$($p.DeviceID)"
        }
    }

    # ---------------- 输入设备 ----------------
    if ($Info.Input) {
        & $sec '输入设备'
        foreach ($k in $Info.Input.Keyboards) { & $add ("  {0,-22}: {1}  [{2}]" -f '键盘', $k.Name, $k.Status) }
        foreach ($p in $Info.Input.Pointing) { & $add ("  {0,-22}: {1}  $($p.Type) [{2}]" -f '指针设备', $p.Name, $p.Status) }
    }

    # ---------------- 电源 ----------------
    if ($Info.Power) {
        & $sec '电源'
        if ($Info.Power.ActivePlan) { & $kv '当前电源计划' $Info.Power.ActivePlan }
        foreach ($b in $Info.Power.Batteries) {
            & $kv '电池' "$($b.Name)（$($b.Chemistry)）"
            & $kv '电池电量' "$($b.EstimatedChargePercent)%  状态:$($b.Status)"
            if ($b.DesignCapacity -gt 0 -and $b.FullChargeCapacity -gt 0) {
                $h = [Math]::Round(($b.FullChargeCapacity / $b.DesignCapacity) * 100, 0)
                & $kv '电池健康度' "$h%（设计 $($b.DesignCapacity) / 满充 $($b.FullChargeCapacity)）"
            }
        }
        if ($Info.Power.Batteries.Count -eq 0) { & $add '  （台式机，无电池）' }
    }

    # ---------------- 温度 ----------------
    if ($Info.Thermal -and ($Info.Thermal.Zones.Count -gt 0 -or $Info.Thermal.Fans.Count -gt 0)) {
        & $sec '温度与风扇'
        foreach ($z in $Info.Thermal.Zones) {
            if ($null -ne $z.Celsius) { & $add ("  {0,-22}: {1} °C" -f $z.Zone, $z.Celsius) }
        }
        foreach ($f in $Info.Thermal.Fans) { & $add ("  {0,-22}: {1}  [{2}]" -f '风扇', $f.Name, $f.Status) }
    }

    # ---------------- 运行库 ----------------
    if ($Info.Runtimes) {
        & $sec '运行库'
        & $kv 'DirectX 注册表版本' $Info.Runtimes.DirectXReg
        & $kv '32 位组件目录' $Info.Runtimes.DirX86
        & $kv '该目录已具备的组件' (($Info.Runtimes.DxX86) -join ', ')
        if ($Info.Runtimes.Vc -and $Info.Runtimes.Vc.Count -gt 0) {
            & $add ''
            & $add ('  {0,-10} {1,-6} {2,-10} {3}' -f 'VC 版本', '位数', '状态', '判定依据')
            & $add ('  ' + ('-' * 74))
            foreach ($v in $Info.Runtimes.Vc) {
                if (-not $v.Applicable) { continue }
                & $add ('  {0,-10} {1,-6} {2,-10} {3}' -f $v.Version, $v.Arch, $(if ($v.Installed) { '已安装' } else { '缺失' }), $v.Source)
            }
        }
        if ($Info.Runtimes.DotNet) {
            & $kv '.NET Framework' "$(if ($Info.Runtimes.DotNet.Has4x) { "4.x（$($Info.Runtimes.DotNet.V4Full)）" } else { '未检测到 4.x' })"
        }
    }

    # ---------------- 安全软件与冲突 ----------------
    if ($Info.Security) {
        & $sec '安全软件'
        if ($Info.Security.Products.Count -eq 0) { & $add '  （未检测到已注册的安全软件）' }
        foreach ($p in $Info.Security.Products) {
            & $add ("  * {0}　{1}" -f $p.Name, $(if ($p.IsDefender) { '（系统自带）' } else { '（第三方）' }))
        }
    }
    if ($Info.Conflicts -and $Info.Conflicts.Count -gt 0) {
        & $add ''
        & $add "  检测到 $($Info.Conflicts.Count) 个可能干扰游戏的常驻进程："
        foreach ($c in $Info.Conflicts) { & $add ("    - [$($c.Category)] $($c.Process)") }
    }

    # ---------------- 关键服务 ----------------
    if ($Info.Services -and $Info.Services.Count -gt 0) {
        & $sec '关键服务'
        & $add ('  {0,-22} {1,-12} {2,-14} {3}' -f '服务', '状态', '启动类型', '说明')
        & $add ('  ' + ('-' * 90))
        foreach ($s in $Info.Services) {
            $mark = if ($s.Problem -eq $true) { '  <== 异常' } else { '' }
            & $add ('  {0,-22} {1,-12} {2,-14} {3}{4}' -f $s.Name, $(if ($s.Status) { $s.Status } else { '查询失败' }), $(if ($s.StartType) { $s.StartType } else { '-' }), $s.Display, $mark)
        }
    }

    # ---------------- 补丁 ----------------
    if ($Info.Hotfixes -and $Info.Hotfixes.Count -gt 0) {
        & $sec '已安装的系统补丁'
        foreach ($h in $Info.Hotfixes) {
            & $add ("  {0,-14} {1,-28} {2}" -f $h.HotFixID, $h.Description, $h.InstalledOn)
        }
    }

    # ---------------- USB ----------------
    if ($Info.UsbDevices -and $Info.UsbDevices.Count -gt 0) {
        & $sec 'USB 设备'
        foreach ($u in $Info.UsbDevices) {
            $mark = if ($u.ErrorCode -ne 0) { "  <== 错误码 $($u.ErrorCode)" } else { '' }
            & $add ("  [{0,-14}] {1}{2}" -f $u.Class, $u.Name, $mark)
        }
    }

    # ---------------- 启动项 ----------------
    if ($Info.Startup -and $Info.Startup.Count -gt 0) {
        & $sec '启动项'
        foreach ($s in $Info.Startup) {
            & $add ("  {0,-28} {1}" -f $s.Name, $s.Command)
            & $add ("  {0,-28} 来源: {1}" -f '', $s.Location)
        }
    }

    & $add ''
    & $add $line
    & $add '  报告结束'
    & $add $line

    return ($L -join "`r`n")
}

# ---------------------------------------------------------------------------
#  精简摘要（适合发论坛求助）
# ---------------------------------------------------------------------------
function New-TrdSysInfoBrief {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Info)

    $L = New-Object System.Collections.ArrayList
    $add = { param([string]$s) $null = $L.Add($s) }

    & $add '【系统】'
    & $add ("  {0}  Build {1}  {2}" -f $Info.OS.Caption, $Info.OS.Build, $Info.OS.Architecture)
    & $add ("  主板: {0} {1}" -f $Info.Identity.BoardVendor, $Info.Identity.BoardProduct)
    & $add ("  区域代码页: {0}   PowerShell: {1}" -f $Info.OS.AcpCodePage, $Info.OS.PsVersion)

    foreach ($c in $Info.CPU) {
        & $add ("【CPU】{0}｜{1}核{2}线程｜{3}MHz" -f $c.Name, $c.Cores, $c.Threads, $c.MaxClockMHz)
        break
    }

    & $add ("【内存】{0} GB（{1}/{2} 插槽）{3}" -f $Info.Memory.InstalledGB, $Info.Memory.UsedSlots, $Info.Memory.SlotCount, $Info.Memory.SpeedSummary)

    foreach ($g in $Info.Graphics) {
        & $add ("【显卡】{0}" -f $g.Name)
        & $add ("        驱动 {0}（{1}）状态 {2}/错误码 {3}" -f `
            $g.DriverVersion,
            $(if ($g.DriverDate) { $g.DriverDate.ToString('yyyy-MM-dd') } else { '未知' }),
            $g.Status, $g.ErrorCode)
        if ($g.IsBasicAdapter) { & $add '        ★ 未安装厂商驱动，只有兜底显示驱动' }
        break
    }
    if ($Info.DisplayModes -and $Info.DisplayModes.Detected) {
        & $add ("        显示模式 {0} 个，含 640x480: {1}" -f $Info.DisplayModes.ModeCount, $(if ($Info.DisplayModes.Has640x480) { '是' } else { '否' }))
    }

    if ($Info.Storage -and $Info.Storage.Disks.Count -gt 0) {
        $d = $Info.Storage.Disks[0]
        & $add ("【硬盘】{0}  {1}  {2}  健康:{3}" -f $d.Model, (Format-TrdSizeGB $d.SizeGB), $d.MediaType, $(if ($d.Health) { $d.Health } else { '未知' }))
    }
    if ($Info.Storage) {
        foreach ($v in $Info.Storage.Volumes) {
            if ($v.DriveType -eq '本地磁盘') {
                & $add ("        分区 {0} 可用 {1}/{2}（已用 {3}%）" -f $v.Drive, (Format-TrdSizeGB $v.FreeGB), (Format-TrdSizeGB $v.TotalGB), $v.UsedPercent)
            }
        }
    }

    if ($Info.Audio) {
        & $add ("【音频】设备 {0} 个，Windows Audio: {1}" -f $Info.Audio.DeviceCount, $Info.Audio.ServiceStatus)
    }

    & $add ("【问题设备】{0} 个" -f $Info.ProblemDevices.Count)
    foreach ($p in $Info.ProblemDevices) {
        & $add ("        - {0}  错误码 {1}: {2}" -f $p.Name, $p.ErrorCode, $p.Meaning)
    }

    $badSvc = @($Info.Services | Where-Object { $_.Problem -eq $true })
    if ($badSvc.Count -gt 0) {
        & $add '【异常服务】'
        foreach ($s in $badSvc) { & $add ("        - {0}（{1}/{2}）" -f $s.Name, $s.Status, $s.StartType) }
    }

    if ($Info.Runtimes) {
        & $add ("【DirectX】{0}" -f $Info.Runtimes.DirectXReg)
        $missingVc = @($Info.Runtimes.Vc | Where-Object { $_.Applicable -and -not $_.Installed })
        if ($missingVc.Count -gt 0) {
            & $add ("【VC 运行库缺失】{0}" -f (($missingVc | ForEach-Object { "$($_.Version) $($_.Arch)" }) -join ', '))
        } else {
            & $add '【VC 运行库】齐全'
        }
    }

    if ($Info.Security -and $Info.Security.Products.Count -gt 0) {
        & $add ("【安全软件】{0}" -f (($Info.Security.Products | ForEach-Object { $_.Name }) -join '、'))
    }
    if ($Info.Conflicts -and $Info.Conflicts.Count -gt 0) {
        & $add ("【可能冲突的常驻进程】{0}" -f (($Info.Conflicts | ForEach-Object { $_.Process }) -join ', '))
    }

    return ($L -join "`r`n")
}

# ---------------------------------------------------------------------------
#  HTML 报告
# ---------------------------------------------------------------------------
function New-TrdSysInfoHtml {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Info)

    $e = { param($t) Get-TrdSafeHtml -Text ([string]$t) }
    $sb = New-Object System.Text.StringBuilder
    $w = { param($s) $null = $sb.AppendLine($s) }

    & $w '<!DOCTYPE html><html lang="zh-CN"><head><meta charset="utf-8">'
    & $w '<title>设备与系统信息报告</title><style>'
    & $w ':root{--bg:#0f1115;--card:#171a21;--fg:#e6e8eb;--dim:#9aa4b2;--line:#262b35;--ok:#30a46c;--bad:#e5484d;--warn:#f5a623}'
    & $w '*{box-sizing:border-box}'
    & $w 'body{margin:0;padding:26px;background:var(--bg);color:var(--fg);font-family:"Microsoft YaHei","Segoe UI",system-ui,sans-serif;line-height:1.65;font-size:14px}'
    & $w 'h1{font-size:21px;margin:0 0 4px}h2{font-size:15px;margin:26px 0 10px;color:#c9d1d9;border-left:3px solid #4c8dff;padding-left:10px}'
    & $w '.sub{color:var(--dim);font-size:12.5px;margin-bottom:18px}'
    & $w '.card{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:14px 16px;margin-bottom:12px}'
    & $w 'table{width:100%;border-collapse:collapse;font-size:13px}'
    & $w 'th,td{text-align:left;padding:6px 10px;border-bottom:1px solid var(--line);vertical-align:top}'
    & $w 'th{color:var(--dim);font-weight:500}'
    & $w 'tr:last-child td{border-bottom:none}'
    & $w 'code{background:#0b0d11;padding:1px 6px;border-radius:4px;font-size:12px;color:#9ecbff}'
    & $w '.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(280px,1fr));gap:8px}'
    & $w '.kv b{color:var(--dim);font-weight:400;display:inline-block;min-width:110px}'
    & $w '.bad{color:var(--bad);font-weight:600}.ok{color:var(--ok)}.warn{color:var(--warn)}'
    & $w '.pill{display:inline-block;padding:1px 8px;border-radius:10px;font-size:11.5px;background:#0b0d11;color:var(--dim)}'
    & $w '</style></head><body>'

    & $w '<h1>设备与系统信息报告</h1>'
    & $w ('<div class="sub">Touhou Runtime Doctor &nbsp;|&nbsp; 采集于 ' + $Info.Meta.CollectedAt.ToString('yyyy-MM-dd HH:mm:ss') +
          ' &nbsp;|&nbsp; PowerShell ' + (& $e $Info.Meta.PsVersion) +
          ' &nbsp;|&nbsp; ' + $(if ($Info.Meta.IsAdmin) { '管理员权限' } else { '普通权限' }) + '</div>')

    # 摘要卡片
    & $w '<h2>系统概览</h2><div class="card grid">'
    $pairs = @(
        @('计算机名', $Info.Identity.ComputerName),
        @('制造商', $Info.Identity.Manufacturer),
        @('型号', $Info.Identity.Model),
        @('机箱', $Info.Identity.ChassisType),
        @('操作系统', "$($Info.OS.Caption)"),
        @('内部版本', "$($Info.OS.Version) (Build $($Info.OS.Build))"),
        @('体系结构', $Info.OS.Architecture),
        @('安装日期', $(if ($Info.OS.InstallDate) { $Info.OS.InstallDate.ToString('yyyy-MM-dd') } else { '-' })),
        @('已运行', (Format-TrdUptime $Info.OS.Uptime)),
        @('系统区域', "$($Info.OS.SystemLocale) ($($Info.OS.AcpCodePage))"),
        @('主板', "$($Info.Identity.BoardVendor) $($Info.Identity.BoardProduct)"),
        @('BIOS', "$($Info.Identity.BiosVendor) $($Info.Identity.BiosVersion)"),
        @('引导模式', $Info.Identity.BiosMode),
        @('物理内存', "$($Info.OS.TotalMemMB) MB（可用 $($Info.OS.FreeMemMB) MB）")
    )
    foreach ($p in $pairs) {
        & $w ('<div class="kv"><b>{0}</b>{1}</div>' -f (& $e $p[0]), (& $e $p[1]))
    }
    & $w '</div>'

    # 问题设备
    $pcls = if ($Info.ProblemDevices.Count -gt 0) { 'bad' } else { 'ok' }
    & $w ('<h2>有问题的设备 <span class="pill {0}">{1}</span></h2><div class="card">' -f $pcls, $Info.ProblemDevices.Count)
    if ($Info.ProblemDevices.Count -eq 0) {
        & $w '<div class="ok">未发现任何状态异常的设备。</div>'
    } else {
        & $w '<table><tr><th>设备</th><th>类别</th><th>错误码</th><th>含义</th></tr>'
        foreach ($p in $Info.ProblemDevices) {
            & $w ('<tr><td>{0}<br><code>{1}</code></td><td>{2}</td><td class="bad">{3}</td><td>{4}</td></tr>' -f
                  (& $e $p.Name), (& $e $p.DeviceID), (& $e $p.Class), $p.ErrorCode, (& $e $p.Meaning))
        }
        & $w '</table>'
    }
    & $w '</div>'

    # CPU
    & $w '<h2>处理器</h2><div class="card"><table><tr><th>型号</th><th>核心/线程</th><th>频率</th><th>缓存</th><th>插槽</th></tr>'
    foreach ($c in $Info.CPU) {
        & $w ('<tr><td>{0}</td><td>{1} / {2}</td><td>{3} MHz（最高 {4}）</td><td>L2 {5} KB / L3 {6} KB</td><td>{7}</td></tr>' -f
              (& $e $c.Name), $c.Cores, $c.Threads, $c.CurClockMHz, $c.MaxClockMHz, $c.L2CacheKB, $c.L3CacheKB, (& $e $c.SocketDesignation))
    }
    & $w '</table></div>'

    # 内存
    & $w ('<h2>内存 <span class="pill">{0} GB</span></h2><div class="card"><table>' -f $Info.Memory.InstalledGB)
    & $w '<tr><th>插槽</th><th>容量</th><th>频率</th><th>类型</th><th>厂商</th><th>型号</th></tr>'
    foreach ($s in $Info.Memory.Slots) {
        & $w ('<tr><td>{0}</td><td>{1} GB</td><td>{2} MHz</td><td>{3}</td><td>{4}</td><td>{5}</td></tr>' -f
              (& $e $s.DeviceLocator), $s.CapacityGB, $s.SpeedMHz, (& $e $s.MemoryType), (& $e $s.Manufacturer), (& $e $s.PartNumber))
    }
    & $w '</table></div>'

    # 显卡
    & $w '<h2>显卡与显示</h2>'
    foreach ($g in $Info.Graphics) {
        $cls = if ($g.IsBasicAdapter -or $g.ErrorCode -ne 0) { 'bad' } else { 'ok' }
        & $w ('<div class="card"><div class="{0}" style="font-weight:600;margin-bottom:6px">{1}</div><div class="grid">' -f $cls, (& $e $g.Name))
        foreach ($p in @(
            @('显存', $(if ($null -ne $g.AdapterRAM_MB) { "$($g.AdapterRAM_MB) MB" } else { '未知' })),
            @('驱动版本', $g.DriverVersion),
            @('驱动日期', $(if ($g.DriverDate) { $g.DriverDate.ToString('yyyy-MM-dd') } else { '未知' })),
            @('设备状态', "$($g.Status)（错误码 $($g.ErrorCode)）"),
            @('当前模式', "$($g.CurWidth)x$($g.CurHeight) @ $($g.CurRefresh)Hz")
        )) { & $w ('<div class="kv"><b>{0}</b>{1}</div>' -f (& $e $p[0]), (& $e $p[1])) }
        & $w '</div>'
        if ($g.IsBasicAdapter) { & $w '<div class="bad" style="margin-top:8px">★ 当前使用 Windows 自带兜底显示驱动：没有 3D 加速，游戏无法建立 Direct3D 设备。</div>' }
        & $w '</div>'
    }
    if ($Info.DisplayModes -and $Info.DisplayModes.Detected) {
        & $w ('<div class="card"><div class="kv"><b>显示模式数</b>{0}</div><div class="kv"><b>含 640×480</b>{1}</div><div class="kv"><b>含 800×600</b>{2}</div><div class="kv"><b>最小模式</b>{3}×{4}</div></div>' -f
              $Info.DisplayModes.ModeCount,
              $(if ($Info.DisplayModes.Has640x480) { '<span class="ok">是</span>' } else { '<span class="bad">否</span>' }),
              $(if ($Info.DisplayModes.Has800x600) { '<span class="ok">是</span>' } else { '<span class="warn">否</span>' }),
              $Info.DisplayModes.MinWidth, $Info.DisplayModes.MinHeight)
    }

    # 显示器
    if ($Info.Monitors.Count -gt 0) {
        & $w '<h2>显示器</h2><div class="card"><table><tr><th>名称</th><th>厂商</th><th>尺寸</th><th>生产</th><th>连接</th></tr>'
        foreach ($m in $Info.Monitors) {
            & $w ('<tr><td>{0}</td><td>{1}</td><td>{2}</td><td>{3}</td><td>{4}</td></tr>' -f
                  (& $e $(if ($m.Name) { $m.Name } else { '(未知)' })), (& $e $m.Vendor),
                  (& $e $(if ($m.DiagonalInch) { "$($m.DiagonalInch) 英寸 ($($m.WidthCm)×$($m.HeightCm) cm)" } else { '-' })),
                  (& $e $(if ($m.Year) { "$($m.Year) 年" } else { '-' })), (& $e $m.Connection))
        }
        & $w '</table></div>'
    }

    # 存储
    if ($Info.Storage) {
        & $w '<h2>存储设备</h2><div class="card"><table><tr><th>编号</th><th>型号</th><th>容量</th><th>接口</th><th>介质</th><th>健康</th></tr>'
        foreach ($d in $Info.Storage.Disks) {
            $hc = if ($d.Health -eq '健康') { 'ok' } elseif ($d.Health) { 'bad' } else { '' }
            & $w ('<tr><td>{0}</td><td>{1}</td><td>{2}</td><td>{3}</td><td>{4}</td><td class="{5}">{6}</td></tr>' -f
                  $d.Index, (& $e $d.Model), (Format-TrdSizeGB $d.SizeGB), (& $e $d.Interface), (& $e $d.MediaType), $hc, (& $e $(if ($d.Health) { $d.Health } else { '-' })))
        }
        & $w '</table></div>'
        & $w '<div class="card"><table><tr><th>盘符</th><th>卷标</th><th>文件系统</th><th>总容量</th><th>可用</th><th>已用</th></tr>'
        foreach ($v in $Info.Storage.Volumes) {
            $uc = if ($v.UsedPercent -ge 90) { 'bad' } elseif ($v.UsedPercent -ge 75) { 'warn' } else { '' }
            & $w ('<tr><td>{0}</td><td>{1}</td><td>{2}</td><td>{3}</td><td>{4}</td><td class="{5}">{6}%</td></tr>' -f
                  (& $e $v.Drive), (& $e $v.Label), (& $e $v.FileSystem), (Format-TrdSizeGB $v.TotalGB), (Format-TrdSizeGB $v.FreeGB), $uc, $v.UsedPercent)
        }
        & $w '</table></div>'
    }

    # 音频
    if ($Info.Audio) {
        $ac = if ($Info.Audio.ServiceRunning) { 'ok' } else { 'bad' }
        & $w ('<h2>音频设备</h2><div class="card"><div class="kv"><b>Windows Audio 服务</b><span class="{0}">{1}</span>（启动类型 {2}）</div><table>' -f
              $ac, (& $e $Info.Audio.ServiceStatus), (& $e $Info.Audio.ServiceStart))
        & $w '<tr><th>设备</th><th>状态</th></tr>'
        foreach ($d in $Info.Audio.Devices) {
            & $w ('<tr><td>{0}</td><td>{1}</td></tr>' -f (& $e $d.Name), (& $e $d.Status))
        }
        & $w '</table></div>'
    }

    # 网络
    if ($Info.Network.Count -gt 0) {
        & $w '<h2>网络适配器</h2><div class="card"><table><tr><th>名称</th><th>类型/状态</th><th>MAC</th><th>IP</th><th>网关</th><th>速率</th></tr>'
        foreach ($n in $Info.Network) {
            & $w ('<tr><td>{0}</td><td>{1} / {2}</td><td><code>{3}</code></td><td>{4}</td><td>{5}</td><td>{6}</td></tr>' -f
                  (& $e $n.Name), (& $e $n.Type), (& $e $n.NetConnectionStatus), (& $e $n.MAC),
                  (& $e (($n.IPAddresses) -join ', ')), (& $e (($n.Gateways) -join ', ')),
                  (& $e $(if ($n.SpeedMbps) { "$($n.SpeedMbps) Mbps" } else { '-' })))
        }
        & $w '</table></div>'
    }

    # 运行库
    if ($Info.Runtimes) {
        & $w ('<h2>运行库</h2><div class="card"><div class="kv"><b>DirectX 版本</b>{0}</div><div class="kv"><b>32 位组件目录</b><code>{1}</code></div><div class="kv"><b>已具备组件</b>{2}</div><table>' -f
              (& $e $Info.Runtimes.DirectXReg), (& $e $Info.Runtimes.DirX86), (& $e (($Info.Runtimes.DxX86) -join ', ')))
        & $w '<tr><th>VC++ 版本</th><th>位数</th><th>状态</th><th>判定依据</th></tr>'
        foreach ($v in $Info.Runtimes.Vc) {
            if (-not $v.Applicable) { continue }
            $c = if ($v.Installed) { 'ok' } else { 'bad' }
            & $w ('<tr><td>{0}</td><td>{1}</td><td class="{2}">{3}</td><td>{4}</td></tr>' -f
                  (& $e $v.Version), (& $e $v.Arch), $c, $(if ($v.Installed) { '已安装' } else { '缺失' }), (& $e $v.Source))
        }
        & $w '</table></div>'
    }

    # 关键服务
    if ($Info.Services -and $Info.Services.Count -gt 0) {
        & $w '<h2>关键服务</h2><div class="card"><table><tr><th>服务</th><th>状态</th><th>启动类型</th><th>说明</th></tr>'
        foreach ($s in $Info.Services) {
            $c = if ($s.Problem -eq $true) { 'bad' } else { '' }
            & $w ('<tr><td><code>{0}</code></td><td class="{1}">{2}</td><td>{3}</td><td>{4}</td></tr>' -f
                  (& $e $s.Name), $c, (& $e $(if ($s.Status) { $s.Status } else { '查询失败' })), (& $e $s.StartType), (& $e $s.Display))
        }
        & $w '</table></div>'
    }

    # 安全软件 / 冲突
    if ($Info.Security -or $Info.Conflicts.Count -gt 0) {
        & $w '<h2>安全软件与潜在冲突</h2><div class="card">'
        if ($Info.Security) {
            foreach ($p in $Info.Security.Products) {
                & $w ('<div class="kv"><b>{0}</b>{1}</div>' -f (& $e $p.Name), $(if ($p.IsDefender) { '系统自带' } else { '<span class="warn">第三方</span>' }))
            }
        }
        if ($Info.Conflicts.Count -gt 0) {
            & $w '<div style="margin-top:8px"><b style="color:var(--dim);font-weight:400">可能干扰游戏的常驻进程</b><ul style="margin:6px 0 0 0;padding-left:18px">'
            foreach ($c in $Info.Conflicts) { & $w ('<li>[{0}] {1}</li>' -f (& $e $c.Category), (& $e $c.Process)) }
            & $w '</ul></div>'
        }
        & $w '</div>'
    }

    # USB
    if ($Info.UsbDevices -and $Info.UsbDevices.Count -gt 0) {
        & $w '<h2>USB 设备</h2><div class="card"><table><tr><th>类别</th><th>名称</th><th>状态</th></tr>'
        foreach ($u in $Info.UsbDevices) {
            $c = if ($u.ErrorCode -ne 0) { 'bad' } else { '' }
            & $w ('<tr><td>{0}</td><td>{1}</td><td class="{2}">{3}</td></tr>' -f
                  (& $e $u.Class), (& $e $u.Name), $c, $(if ($u.ErrorCode -ne 0) { "错误码 $($u.ErrorCode)" } else { (& $e $u.Status) }))
        }
        & $w '</table></div>'
    }

    # 补丁
    if ($Info.Hotfixes -and $Info.Hotfixes.Count -gt 0) {
        & $w '<h2>系统补丁</h2><div class="card"><table><tr><th>编号</th><th>说明</th><th>安装日期</th></tr>'
        foreach ($h in $Info.Hotfixes) {
            & $w ('<tr><td><code>{0}</code></td><td>{1}</td><td>{2}</td></tr>' -f (& $e $h.HotFixID), (& $e $h.Description), (& $e $h.InstalledOn))
        }
        & $w '</table></div>'
    }

    & $w ('<div class="sub" style="margin-top:26px">采集工具：{0} &nbsp;|&nbsp; {1} &nbsp;|&nbsp; 本报告为只读采集，未修改任何系统设置。</div>' -f
          (& $e $Info.Meta.Tool), (& $e $Info.Meta.CollectedAt.ToString('yyyy-MM-dd HH:mm:ss')))
    & $w '</body></html>'

    return $sb.ToString()
}

# ---------------------------------------------------------------------------
#  JSON
# ---------------------------------------------------------------------------
function New-TrdSysInfoJson {
    <#
    .SYNOPSIS
        把采集结果序列化成可读的 JSON。
    .DESCRIPTION
        PowerShell 5.1 的 ConvertTo-Json 会把所有非 ASCII 字符转义成 \uXXXX，
        导出的文件完全没法人肉看。而设备信息报告的一个主要用途恰恰是
        贴给别人看、或者跨机器 diff。所以这里把转义还原回原字符。
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Info)

    # DateTime 先转成字符串，否则 JSON 里会是一串难读的序列化结构
    $flat = ConvertTo-TrdJsonFriendly -InputObject $Info
    $json = ConvertTo-Json -InputObject $flat -Depth 12

    # \uXXXX -> 原字符
    $json = [regex]::Replace($json, '\\u([0-9a-fA-F]{4})', {
        param($m)
        [char][Convert]::ToInt32($m.Groups[1].Value, 16)
    })
    return $json
}

function ConvertTo-TrdJsonFriendly {
    <#
    .SYNOPSIS
        递归把对象树里的 DateTime / TimeSpan 转成字符串，便于 JSON 序列化。
    .DESCRIPTION
        标量判定用 Type.IsPrimitive / IsEnum，而不是一个个 -is 列举。
        原因是 WMI 会返回 UInt16/UInt32/UInt64/Byte/Single 等一大票数值类型，
        逐个列举必然漏，漏掉的值会掉进"对象"分支，在那里访问
        .PSObject.Properties.Count 直接抛异常
        （Set-StrictMode 2.0 下该成员集合不暴露 Count）。
    #>
    param($InputObject, [int]$Depth = 0)

    if ($null -eq $InputObject) { return $null }
    if ($Depth -gt 12) { return [string]$InputObject }

    if ($InputObject -is [datetime]) { return $InputObject.ToString('yyyy-MM-dd HH:mm:ss') }
    if ($InputObject -is [timespan]) { return (Format-TrdUptime $InputObject) }

    $t = $InputObject.GetType()
    if ($t.IsPrimitive -or $t.IsEnum -or
        $InputObject -is [string] -or $InputObject -is [decimal] -or $InputObject -is [guid]) {
        return $InputObject
    }

    if ($InputObject -is [System.Collections.IEnumerable]) {
        $arr = New-Object System.Collections.ArrayList
        foreach ($x in $InputObject) { $null = $arr.Add((ConvertTo-TrdJsonFriendly -InputObject $x -Depth ($Depth + 1))) }
        return @($arr)
    }

    # 注意必须写 @(...).Count：Set-StrictMode 2.0 下
    # $obj.PSObject.Properties.Count 对任何对象都会抛 PropertyNotFoundException。
    if (@($InputObject.PSObject.Properties).Count -gt 0) {
        $o = [ordered]@{}
        foreach ($p in @($InputObject.PSObject.Properties)) {
            if ($p.Name -like 'PS*' -or $p.Name -eq 'CimClass' -or $p.Name -eq 'CimInstanceProperties' -or
                $p.Name -eq 'CimSystemProperties' -or $p.Name -eq 'Qualifiers' -or $p.Name -eq 'SystemProperties' -or
                $p.Name -eq 'Properties' -or $p.Name -eq 'ClassPath' -or $p.Name -eq 'Site' -or $p.Name -eq 'Container' -or
                $p.Name -eq 'Scope' -or $p.Name -eq 'Options' -or $p.Name -eq 'Path') { continue }
            try {
                $o[$p.Name] = ConvertTo-TrdJsonFriendly -InputObject $p.Value -Depth ($Depth + 1)
            } catch { }
        }
        return $o
    }

    return [string]$InputObject
}

# ---------------------------------------------------------------------------
#  落盘
# ---------------------------------------------------------------------------
function Save-TrdSysInfoReports {
    <#
    .SYNOPSIS
        生成并写出全部四种格式的设备信息报告。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Info,
        [Parameter(Mandatory = $true)][string]$OutDir,
        [string]$FilePrefix = '设备信息'
    )

    if (-not (Test-Path -LiteralPath $OutDir)) { $null = New-Item -ItemType Directory -Path $OutDir -Force }

    $txt   = New-TrdSysInfoText  -Info $Info
    $brief = New-TrdSysInfoBrief -Info $Info
    $html  = New-TrdSysInfoHtml  -Info $Info
    $json  = New-TrdSysInfoJson  -Info $Info

    $gbk = [System.Text.Encoding]::GetEncoding(936)
    $utf8 = New-Object System.Text.UTF8Encoding($false)

    $p = [PSCustomObject]@{
        Txt   = Join-Path $OutDir "$FilePrefix.txt"
        Brief = Join-Path $OutDir "$FilePrefix-精简.txt"
        Html  = Join-Path $OutDir "$FilePrefix.html"
        Json  = Join-Path $OutDir "$FilePrefix.json"
    }

    [System.IO.File]::WriteAllText($p.Txt,   (Get-TrdSafeGbk -Text $txt),  $gbk)
    [System.IO.File]::WriteAllText($p.Brief, (Get-TrdSafeGbk -Text $brief), $gbk)
    [System.IO.File]::WriteAllText($p.Html,  $html, $utf8)
    [System.IO.File]::WriteAllText($p.Json,  $json, $utf8)

    return $p
}
