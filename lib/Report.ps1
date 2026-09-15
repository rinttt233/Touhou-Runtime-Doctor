# ============================================================================
#  Report.ps1 -- 报告生成
#
#  两种格式，各有明确用途：
#   * 修复报告.txt  -- 系统 ANSI(GBK) 编码，双击即可用记事本打开，不依赖浏览器。
#                     刻意只使用 GBK 能表示的字符，避免出现一堆问号。
#   * 修复报告.html -- 带颜色和分级，便于快速扫读与截图分享。
#
#  报告不只是"结论清单"，还必须包含【证据】与【整机状态表】，
#  这样即使结论有偏差，用户也能自己复核原始数据。
# ============================================================================
Set-StrictMode -Version 2.0

function ConvertTo-TrdGbkSafe {
    <#
    .SYNOPSIS
        把文本里 GBK 无法表示的字符替换成安全的替代符号。
    .DESCRIPTION
        直接把含 Unicode 装饰符（如制表符 ═、对勾 ✓）的文本按 GBK 写盘，
        这些字符会静默变成 '?'，报告里会出现一排问号，非常难看。
        这里显式做一次替换，保证输出可读。
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Text)

    # 显示前先把 Sysnative 还原成 System32（见 ConvertTo-TrdDisplayPath）
    $Text = ConvertTo-TrdDisplayPath -Text $Text

    # 用"码位, 替代文本"的列表程序化构建映射表。
    # 不写字面量哈希表的原因：制表符系列里好几个码位都映射到 '+'，
    # 字面量哈希表遇到重复键会直接抛 DuplicateKeyInHashLiteral 而崩溃。
    $pairs = @(
        @(0x2550, '='), @(0x2551, '|'), @(0x2554, '+'), @(0x2557, '+'),
        @(0x255A, '+'), @(0x255D, '+'), @(0x2560, '+'), @(0x2563, '+'),
        @(0x2566, '+'), @(0x2569, '+'), @(0x256C, '+'),
        @(0x2500, '-'), @(0x2502, '|'), @(0x251C, '+'), @(0x2524, '+'),
        @(0x252C, '+'), @(0x2534, '+'), @(0x253C, '+'),
        @(0x2713, 'v'), @(0x2717, 'x'), @(0x25CF, '*'), @(0x25A0, '#'),
        @(0x25B6, '>'), @(0x25C0, '<'),
        @(0x2192, '->'), @(0x2190, '<-'), @(0x21D2, '=>'),
        @(0x2026, '...'), @(0x2265, '>='), @(0x2264, '<='), @(0x00D7, 'x'),
        # 以下这些常见符号不在 GBK 字符集内。硬件名称里很常见
        # （例如音频设备名 "英特尔® 智音技术"），直接退化成 '?' 会让报告
        # 看起来像乱码，所以给它们一个可读的 ASCII 替身。
        @(0x00AE, '(R)'), @(0x00A9, '(C)'), @(0x2122, '(TM)'),
        @(0x2018, "'"), @(0x2019, "'"), @(0x201C, '"'), @(0x201D, '"'),
        @(0x2013, '-'), @(0x2014, '--'), @(0x2015, '--'),
        @(0x2022, '*'), @(0x25AA, '*'), @(0x25CB, 'o'),
        @(0x00A0, ' '), @(0x2007, ' '), @(0x202F, ' '),
        @(0x2212, '-'), @(0x00B1, '+/-'), @(0x00B0, 'deg'),
        @(0x2103, 'degC'), @(0x2109, 'degF'),
        @(0x00B7, '.'), @(0x30FB, '.'), @(0x2215, '/'),
        @(0x2500, '-'), @(0x2501, '='), @(0x2504, '-'),
        @(0x2731, '*'), @(0x2605, '*'), @(0x2606, '*'),
        @(0x26A0, '!'), @(0x2139, 'i'), @(0x2714, 'v'), @(0x2718, 'x')
    )
    $map = @{}
    foreach ($p in $pairs) { $map[[char]$p[0]] = $p[1] }

    $gbk = [System.Text.Encoding]::GetEncoding(936)
    $sb = New-Object System.Text.StringBuilder
    $dropped = 0

    for ($i = 0; $i -lt $Text.Length; $i++) {
        $ch = $Text[$i]
        if ([int]$ch -gt 0xFFFF) { $dropped++; continue }    # 代理对（emoji 等）丢弃

        if ($map.ContainsKey($ch)) { $null = $sb.Append($map[$ch]); continue }

        if ([int]$ch -lt 128) { $null = $sb.Append($ch); continue }

        # 能编码就保留
        $bytes = $gbk.GetBytes([string]$ch)
        if ($bytes.Length -eq 1 -and $bytes[0] -eq 0x3F -and $ch -ne '?') {
            # 无法编码。这里【丢弃】而不是写 '?'：
            # 写 '?' 会让用户以为报告本身或他的文件出了乱码，
            # 丢弃只会让某个生僻符号消失，可读性反而更好。
            $dropped++
        } else {
            $null = $sb.Append($ch)
        }
    }

    $result = $sb.ToString()
    if ($dropped -gt 0) {
        # 显式告知有字符被丢弃，避免"静默丢信息"。
        $result += "`r`n`r`n（注：本报告以 GBK 编码保存，其中有 $dropped 个 GBK 无法表示的字符已被省略。）"
    }
    return $result
}

function Get-TrdSeverityBadge {
    param([string]$Severity)
    switch ($Severity) {
        'Blocker' { return '严重' }
        'High'    { return '高' }
        'Medium'  { return '中' }
        'Low'     { return '低' }
        'Pass'    { return '正常' }
        default   { return $Severity }
    }
}

function Get-TrdSeverityColor {
    param([string]$Severity)
    switch ($Severity) {
        'Blocker' { return '#e5484d' }
        'High'    { return '#f76b15' }
        'Medium'  { return '#f5a623' }
        'Low'     { return '#8b8b8b' }
        'Pass'    { return '#30a46c' }
        default   { return '#8b8b8b' }
    }
}

function ConvertTo-TrdHtmlSafe {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    $Text = ConvertTo-TrdDisplayPath -Text $Text
    return ($Text -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;' -replace '"', '&quot;')
}

# ---------------------------------------------------------------------------
#  纯文本报告
# ---------------------------------------------------------------------------
function New-TrdTextReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Diagnosis,
        [object]$RepairLog,
        [object]$SmokeResult,
        [string]$ToolRoot,
        [string]$OfflineRoot,
        [string[]]$ManualSteps = @()
    )

    $L = New-Object System.Collections.ArrayList
    $add = { param([string]$s) $null = $L.Add($s) }

    $line = '=' * 78
    $sub  = '-' * 78

    & $add $line
    & $add '  Touhou Runtime Doctor  东方 Project 运行环境体检修复报告'
    & $add $line
    & $add ''
    & $add "生成时间   : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    & $add "工具位置   : $ToolRoot"
    & $add "离线载荷   : $(if (Test-TrdOfflineAvailable) { "已就绪 ($OfflineRoot)" } else { "无（$OfflineRoot 为空）" })"
    & $add "管理员权限 : $(if ($script:TRD.IsAdmin) { '是' } else { '否（部分修复需要管理员权限）' })"
    & $add "本次备份   : $($script:TRD.SessionDir)"
    & $add ''
    & $add '【目标游戏】'
    & $add "  作品       : $($Diagnosis.Game.DisplayName)"
    & $add "  代号       : $($Diagnosis.Game.Id)"
    & $add "  目录       : $($Diagnosis.Game.Folder)"
    & $add "  主程序     : $(Split-Path -Leaf $Diagnosis.Game.MainExe)  ($($Diagnosis.Deps.MainArch) 位)"
    & $add "  引擎世代   : $(if ($Diagnosis.Game.Engine -eq 'dx8') { 'DirectX 8' } elseif ($Diagnosis.Game.Engine -eq 'dx9') { 'DirectX 9' } else { '未能识别' })"
    & $add "  启动器     : $(if ($Diagnosis.Game.LauncherExe) { Split-Path -Leaf $Diagnosis.Game.LauncherExe } else { '（无，直接用主程序）' })"
    & $add ''
    & $add '【体检结论】'
    & $add "  严重(无法启动) : $($Diagnosis.Summary.Blocker)"
    & $add "  高             : $($Diagnosis.Summary.High)"
    & $add "  中             : $($Diagnosis.Summary.Medium)"
    & $add "  低             : $($Diagnosis.Summary.Low)"
    & $add "  正常           : $($Diagnosis.Summary.Pass)"
    & $add ''
    $verdictText = switch ($Diagnosis.Summary.Verdict) {
        'REPAIR_NEEDED'      { '发现会导致游戏无法启动的问题，必须修复。' }
        'REPAIR_RECOMMENDED' { '存在高风险项，建议修复以获得稳定体验。' }
        'MINOR_ISSUES'       { '可以运行，但有几处体验问题值得处理。' }
        'HEALTHY'            { '环境健康，未发现需要处理的问题。' }
        default              { '' }
    }
    & $add "  >> $verdictText"
    & $add ''

    if ($SmokeResult) {
        & $add '【启动验证】'
        $vmap = @{ 'PASSED' = '通过：游戏成功启动并创建了窗口'; 'PARTIAL' = '部分通过：进程存在但未检测到窗口';
                   'FAILED' = '失败：游戏未能启动'; 'UNKNOWN' = '未确定'; 'SKIPPED' = '已跳过' }
        & $add "  结果   : $(if ($vmap.ContainsKey($SmokeResult.Verdict)) { $vmap[$SmokeResult.Verdict] } else { $SmokeResult.Verdict })"
        & $add "  说明   : $($SmokeResult.Message)"
        if ($SmokeResult.ExitCodeHex) { & $add "  退出码 : $($SmokeResult.ExitCodeHex)" }
        if ($SmokeResult.NtStatus)    { & $add "  病因   : $($SmokeResult.NtStatus.Name) - $($SmokeResult.NtStatus.Meaning)" }
        if ($SmokeResult.WindowTitle) { & $add "  窗口标题: $($SmokeResult.WindowTitle)" }
        & $add ''
    }

    if ($RepairLog) {
        & $add '【修复执行记录】'
        if ($RepairLog.Count -eq 0) {
            & $add '  （本次没有执行任何修复动作）'
        } else {
            foreach ($r in $RepairLog) {
                $mark = if ($r.Ok) { '[完成]' } else { '[未完成]' }
                & $add "  $mark $($r.Title)"
                if ($r.Message) { & $add "         $($r.Message)" }
            }
        }
        & $add ''
    }

    & $add $sub
    & $add '  逐条结论（按严重程度排序）'
    & $add $sub
    & $add ''
    foreach ($f in $Diagnosis.Findings) {
        & $add ("[{0}] {1}" -f (Get-TrdSeverityBadge -Severity $f.Severity), $f.Title)
        & $add ("      分类: {0}" -f $f.Category)
        if ($f.Detail) { & $add ("      说明: {0}" -f $f.Detail) }
        if ($f.Evidence -and $f.Evidence.Count -gt 0) {
            & $add '      证据:'
            foreach ($e in $f.Evidence) { & $add ("        - {0}" -f $e) }
        }
        if ($f.FixHint) { & $add ("      处理: {0}" -f $f.FixHint) }
        & $add ''
    }

    # ---------------- 整机状态表 ----------------
    & $add $sub
    & $add '  整机 Visual C++ 运行库状态'
    & $add $sub
    & $add ''
    & $add ('  {0,-8} {1,-6} {2,-8} {3}' -f '版本', '位数', '状态', '判定依据')
    & $add ('  ' + ('-' * 74))
    foreach ($v in $Diagnosis.Vc) {
        if (-not $v.Applicable) { continue }
        $st = if ($v.Installed) { '已安装' } else { '缺失' }
        & $add ('  {0,-8} {1,-6} {2,-8} {3}' -f $v.Version, $v.Arch, $st, $v.Source)
    }
    & $add ''
    & $add '  说明: VC++ 2005/2008 通过 WinSxS 并行程序集部署，磁盘 system32 下查不到属正常现象;'
    & $add '        因此本工具的判定同时依据 注册表 + 系统目录 DLL + WinSxS 三处证据。'
    & $add ''

    & $add $sub
    & $add ("  DirectX 组件状态（32 位程序运行时目录: {0}）" -f $Diagnosis.Dx.X86Dir)
    & $add $sub
    & $add ''
    $dxKeys = @($Diagnosis.Dx.X86.Keys | Sort-Object)
    $present = @($dxKeys | Where-Object { $Diagnosis.Dx.X86[$_] })
    $absent  = @($dxKeys | Where-Object { -not $Diagnosis.Dx.X86[$_] })
    & $add "  注册表版本      : $($Diagnosis.Dx.RegVersion)"
    & $add "  系统类型        : $(if ($Diagnosis.Dx.Is64OS) { '64 位（32 位程序走 SysWOW64）' } else { '32 位（32 位程序直接在 System32 运行）' })"
    & $add "  已存在组件 ($($present.Count)) : $($present -join ', ')"
    & $add "  缺失组件   ($($absent.Count)) : $(if ($absent.Count -gt 0) { $absent -join ', ' } else { '（无）' })"
    & $add ''

    & $add $sub
    & $add '  PE 依赖解析明细（来自程序导入表，不是猜测）'
    & $add $sub
    & $add ''
    & $add "  解析文件数: $($Diagnosis.Deps.Exes.Count)   依赖项总数: $($Diagnosis.Deps.TotalDeps)   已解析: $($Diagnosis.Deps.OkCount)"
    & $add ''
    foreach ($e in $Diagnosis.Deps.Exes) {
        if ($e.Ok) {
            & $add "  $($e.Name)  [$($e.Arch)]"
            & $add "      导入: $($e.Imports -join ', ')"
        } else {
            & $add "  $($e.Name)  [解析失败] $($e.Error)"
        }
    }
    & $add ''

    if ($ManualSteps.Count -gt 0) {
        & $add $sub
        & $add '  需要手动完成的步骤（无法自动处理）'
        & $add $sub
        & $add ''
        foreach ($s in $ManualSteps) { & $add "  * $s" }
        & $add ''
    }

    & $add $line
    & $add '  报告结束'
    & $add $line

    return ($L -join "`r`n")
}

# ---------------------------------------------------------------------------
#  HTML 报告
# ---------------------------------------------------------------------------
function New-TrdHtmlReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Diagnosis,
        [object]$RepairLog,
        [object]$SmokeResult,
        [string]$ToolRoot,
        [string]$OfflineRoot,
        [string[]]$ManualSteps = @()
    )

    $e = { param($t) ConvertTo-TrdHtmlSafe -Text ([string]$t) }

    $sb = New-Object System.Text.StringBuilder
    $w = { param($s) $null = $sb.AppendLine($s) }

    & $w '<!DOCTYPE html>'
    & $w '<html lang="zh-CN"><head><meta charset="utf-8">'
    & $w '<title>Touhou Runtime Doctor 体检报告</title>'
    & $w '<style>'
    & $w ':root{--bg:#0f1115;--card:#171a21;--fg:#e6e8eb;--dim:#9aa4b2;--line:#262b35;}'
    & $w '*{box-sizing:border-box}'
    & $w 'body{margin:0;padding:28px;background:var(--bg);color:var(--fg);'
    & $w 'font-family:"Microsoft YaHei","Segoe UI",system-ui,sans-serif;line-height:1.7;}'
    & $w 'h1{font-size:22px;margin:0 0 4px;} h2{font-size:16px;margin:28px 0 12px;color:#c9d1d9;'
    & $w 'border-left:3px solid #4c8dff;padding-left:10px;}'
    & $w '.sub{color:var(--dim);font-size:13px;margin-bottom:20px;}'
    & $w '.card{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:16px 18px;margin-bottom:14px;}'
    & $w '.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(240px,1fr));gap:10px;}'
    & $w '.kv{font-size:13px;} .kv b{color:var(--dim);font-weight:400;display:inline-block;min-width:86px;}'
    & $w '.stat{display:inline-block;padding:10px 18px;border-radius:8px;margin:0 10px 10px 0;'
    & $w 'background:var(--card);border:1px solid var(--line);text-align:center;min-width:88px;}'
    & $w '.stat .n{font-size:24px;font-weight:700;display:block;} .stat .l{font-size:12px;color:var(--dim);}'
    & $w '.f{border-left:4px solid #666;padding:12px 16px;margin-bottom:10px;background:var(--card);border-radius:0 8px 8px 0;}'
    & $w '.f .t{font-weight:600;} .f .m{font-size:12px;color:var(--dim);margin-top:2px;}'
    & $w '.f ul{margin:8px 0 0 0;padding-left:18px;font-size:12.5px;color:#b9c1cc;}'
    & $w '.fix{font-size:12.5px;color:#7ee2a8;margin-top:8px;}'
    & $w 'table{width:100%;border-collapse:collapse;font-size:13px;}'
    & $w 'th,td{text-align:left;padding:7px 10px;border-bottom:1px solid var(--line);}'
    & $w 'th{color:var(--dim);font-weight:500;}'
    & $w 'code{background:#0b0d11;padding:1px 6px;border-radius:4px;font-size:12.5px;color:#9ecbff;}'
    & $w '.banner{padding:16px 20px;border-radius:10px;font-size:15px;font-weight:600;margin-bottom:18px;}'
    & $w '</style></head><body>'

    & $w '<h1>Touhou Runtime Doctor</h1>'
    & $w ('<div class="sub">东方 Project 运行环境体检修复报告 &nbsp;|&nbsp; ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '</div>')

    # 结论横幅
    $bannerBg = switch ($Diagnosis.Summary.Verdict) {
        'REPAIR_NEEDED'      { '#3a1416' } 'REPAIR_RECOMMENDED' { '#3a2410' }
        'MINOR_ISSUES'       { '#33301a' } default { '#12301f' }
    }
    $bannerFg = switch ($Diagnosis.Summary.Verdict) {
        'REPAIR_NEEDED'      { '#ff9b9e' } 'REPAIR_RECOMMENDED' { '#ffc38a' }
        'MINOR_ISSUES'       { '#ffe08a' } default { '#8ee6b0' }
    }
    $bannerText = switch ($Diagnosis.Summary.Verdict) {
        'REPAIR_NEEDED'      { '发现会导致游戏无法启动的问题，需要修复' }
        'REPAIR_RECOMMENDED' { '存在高风险项，建议修复' }
        'MINOR_ISSUES'       { '游戏可以运行，但有几处体验问题值得处理' }
        'HEALTHY'            { '环境健康，未发现需要处理的问题' }
        default              { '' }
    }
    & $w ('<div class="banner" style="background:{0};color:{1}">{2}</div>' -f $bannerBg, $bannerFg, (& $e $bannerText))

    # 统计
    & $w '<div>'
    foreach ($pair in @(@('严重', $Diagnosis.Summary.Blocker, '#e5484d'),
                        @('高', $Diagnosis.Summary.High, '#f76b15'),
                        @('中', $Diagnosis.Summary.Medium, '#f5a623'),
                        @('低', $Diagnosis.Summary.Low, '#8b8b8b'),
                        @('正常', $Diagnosis.Summary.Pass, '#30a46c'))) {
        & $w ('<div class="stat"><span class="n" style="color:{0}">{1}</span><span class="l">{2}</span></div>' -f $pair[2], $pair[1], $pair[0])
    }
    & $w '</div>'

    # 启动验证
    if ($SmokeResult) {
        & $w '<h2>启动验证</h2><div class="card">'
        $vc = switch ($SmokeResult.Verdict) {
            'PASSED' { '#30a46c' } 'FAILED' { '#e5484d' } 'PARTIAL' { '#f5a623' } default { '#8b8b8b' }
        }
        & $w ('<div style="color:{0};font-weight:600">{1}</div>' -f $vc, (& $e $SmokeResult.Message))
        if ($SmokeResult.ExitCodeHex) { & $w ('<div class="kv" style="margin-top:8px"><b>退出码</b><code>{0}</code></div>' -f (& $e $SmokeResult.ExitCodeHex)) }
        if ($SmokeResult.NtStatus) {
            & $w ('<div class="kv"><b>病因</b>{0} - {1}</div>' -f (& $e $SmokeResult.NtStatus.Name), (& $e $SmokeResult.NtStatus.Meaning))
            & $w ('<div class="kv"><b>建议</b>{0}</div>' -f (& $e $SmokeResult.NtStatus.Hint))
        }
        if ($SmokeResult.WindowTitle) { & $w ('<div class="kv"><b>窗口标题</b>{0}</div>' -f (& $e $SmokeResult.WindowTitle)) }
        & $w '</div>'
    }

    # 目标信息
    & $w '<h2>目标游戏</h2><div class="card grid">'
    & $w ('<div class="kv"><b>作品</b>{0}</div>' -f (& $e $Diagnosis.Game.DisplayName))
    & $w ('<div class="kv"><b>目录</b>{0}</div>' -f (& $e $Diagnosis.Game.Folder))
    & $w ('<div class="kv"><b>主程序</b>{0} ({1} 位)</div>' -f (& $e (Split-Path -Leaf $Diagnosis.Game.MainExe)), $Diagnosis.Deps.MainArch)
    & $w ('<div class="kv"><b>引擎</b>{0}</div>' -f (& $e $Diagnosis.Game.Engine))
    & $w ('<div class="kv"><b>启动器</b>{0}</div>' -f (& $e $(if ($Diagnosis.Game.LauncherExe) { Split-Path -Leaf $Diagnosis.Game.LauncherExe } else { '无' })))
    & $w ('<div class="kv"><b>离线载荷</b>{0}</div>' -f (& $e $(if (Test-TrdOfflineAvailable) { '已就绪' } else { '无' })))
    & $w '</div>'

    # 修复记录
    if ($RepairLog -and $RepairLog.Count -gt 0) {
        & $w '<h2>修复执行记录</h2><div class="card"><table><tr><th>结果</th><th>动作</th><th>说明</th></tr>'
        foreach ($r in $RepairLog) {
            $c = if ($r.Ok) { '#30a46c' } else { '#e5484d' }
            $m = if ($r.Ok) { '完成' } else { '未完成' }
            & $w ('<tr><td style="color:{0}">{1}</td><td>{2}</td><td style="color:#b9c1cc">{3}</td></tr>' -f $c, $m, (& $e $r.Title), (& $e $r.Message))
        }
        & $w '</table></div>'
    }

    # 结论
    & $w '<h2>逐条结论</h2>'
    foreach ($f in $Diagnosis.Findings) {
        $c = Get-TrdSeverityColor -Severity $f.Severity
        & $w ('<div class="f" style="border-left-color:{0}">' -f $c)
        & $w ('<div class="t">{0} <span style="color:{1};font-size:12px;font-weight:400">[{2}]</span></div>' -f (& $e $f.Title), $c, (Get-TrdSeverityBadge -Severity $f.Severity))
        & $w ('<div class="m">{0}</div>' -f (& $e $f.Category))
        if ($f.Detail) { & $w ('<div style="font-size:13.5px;margin-top:6px">{0}</div>' -f (& $e $f.Detail)) }
        if ($f.Evidence -and $f.Evidence.Count -gt 0) {
            & $w '<ul>'
            foreach ($ev in $f.Evidence) { & $w ('<li>{0}</li>' -f (& $e $ev)) }
            & $w '</ul>'
        }
        if ($f.FixHint) { & $w ('<div class="fix">处理: {0}</div>' -f (& $e $f.FixHint)) }
        & $w '</div>'
    }

    # VC 表
    & $w '<h2>整机 Visual C++ 运行库状态</h2><div class="card"><table>'
    & $w '<tr><th>版本</th><th>位数</th><th>状态</th><th>判定依据</th></tr>'
    foreach ($v in $Diagnosis.Vc) {
        if (-not $v.Applicable) { continue }
        $c = if ($v.Installed) { '#30a46c' } else { '#e5484d' }
        $t = if ($v.Installed) { '已安装' } else { '缺失' }
        & $w ('<tr><td>{0}</td><td>{1}</td><td style="color:{2}">{3}</td><td style="color:#9aa4b2">{4}</td></tr>' -f
              (& $e $v.Version), (& $e $v.Arch), $c, $t, (& $e $v.Source))
    }
    & $w '</table><div class="sub" style="margin:10px 0 0">VC++ 2005/2008 通过 WinSxS 并行程序集部署，system32 下查不到属正常现象；本工具同时依据注册表、系统目录与 WinSxS 三处证据判定。</div></div>'

    # DirectX 表
    & $w ('<h2>DirectX 组件状态（32 位程序运行时目录）</h2><div class="card"><div class="sub" style="margin:0 0 10px">目录: <code>{0}</code> &nbsp;|&nbsp; 系统类型: {1}</div><table>' -f
          (& $e $Diagnosis.Dx.X86Dir),
          (& $e $(if ($Diagnosis.Dx.Is64OS) { '64 位（32 位程序走 SysWOW64）' } else { '32 位（32 位程序直接在 System32 运行）' })))
    & $w '<tr><th>组件</th><th>状态</th></tr>'
    foreach ($k in (@($Diagnosis.Dx.X86.Keys | Sort-Object))) {
        $ok = $Diagnosis.Dx.X86[$k]
        $c = if ($ok) { '#30a46c' } else { '#e5484d' }
        $t = if ($ok) { '存在' } else { '缺失' }
        & $w ('<tr><td><code>{0}</code></td><td style="color:{1}">{2}</td></tr>' -f (& $e $k), $c, $t)
    }
    & $w '</table></div>'

    # 依赖明细
    & $w '<h2>PE 依赖解析明细</h2><div class="card">'
    & $w ('<div class="sub" style="margin:0 0 10px">解析 {0} 个文件，共 {1} 项依赖，已解析 {2} 项。依赖来自程序导入表，不是猜测。</div>' -f
          $Diagnosis.Deps.Exes.Count, $Diagnosis.Deps.TotalDeps, $Diagnosis.Deps.OkCount)
    foreach ($ex in $Diagnosis.Deps.Exes) {
        if ($ex.Ok) {
            & $w ('<div style="margin-bottom:10px"><b>{0}</b> <span style="color:#9aa4b2">[{1}]</span><br><code style="font-size:11.5px">{2}</code></div>' -f
                  (& $e $ex.Name), (& $e $ex.Arch), (& $e ($ex.Imports -join ', ')))
        } else {
            & $w ('<div style="margin-bottom:10px;color:#e5484d"><b>{0}</b> 解析失败: {1}</div>' -f (& $e $ex.Name), (& $e $ex.Error))
        }
    }
    & $w '</div>'

    if ($ManualSteps.Count -gt 0) {
        & $w '<h2>需要手动完成的步骤</h2><div class="card"><ul>'
        foreach ($s in $ManualSteps) { & $w ('<li>{0}</li>' -f (& $e $s)) }
        & $w '</ul></div>'
    }

    & $w ('<div class="sub" style="margin-top:30px">工具位置 {0} &nbsp;|&nbsp; 本次备份 {1}</div>' -f (& $e $ToolRoot), (& $e $script:TRD.SessionDir))
    & $w '</body></html>'

    return $sb.ToString()
}

function Save-TrdReports {
    <#
    .SYNOPSIS
        生成并落盘两种格式的报告。
    .OUTPUTS
        PSCustomObject: TxtPath, HtmlPath
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Diagnosis,
        [object]$RepairLog,
        [object]$SmokeResult,
        [string]$ToolRoot,
        [string]$OfflineRoot,
        [string[]]$ManualSteps = @()
    )

    $txt = New-TrdTextReport -Diagnosis $Diagnosis -RepairLog $RepairLog -SmokeResult $SmokeResult `
            -ToolRoot $ToolRoot -OfflineRoot $OfflineRoot -ManualSteps $ManualSteps
    $html = New-TrdHtmlReport -Diagnosis $Diagnosis -RepairLog $RepairLog -SmokeResult $SmokeResult `
            -ToolRoot $ToolRoot -OfflineRoot $OfflineRoot -ManualSteps $ManualSteps

    $txtPath  = Join-Path $ToolRoot '修复报告.txt'
    $htmlPath = Join-Path $ToolRoot '修复报告.html'

    # 文本报告用系统 ANSI(GBK) 编码：记事本双击打开即可正确显示，
    # 不必担心里面出现一屏问号。
    $gbk = [System.Text.Encoding]::GetEncoding(936)
    [System.IO.File]::WriteAllText($txtPath, (ConvertTo-TrdGbkSafe -Text $txt), $gbk)
    [System.IO.File]::WriteAllText($htmlPath, $html, (New-Object System.Text.UTF8Encoding($false)))

    # 同时在备份会话目录留一份带时间戳的存档，便于对比修复前后的差异
    try {
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        [System.IO.File]::WriteAllText((Join-Path $script:TRD.SessionDir "report-$stamp.txt"), (ConvertTo-TrdGbkSafe -Text $txt), $gbk)
        [System.IO.File]::WriteAllText((Join-Path $script:TRD.SessionDir "report-$stamp.html"), $html, (New-Object System.Text.UTF8Encoding($false)))
    } catch { }

    return [PSCustomObject]@{ TxtPath = $txtPath; HtmlPath = $htmlPath }
}
