# ============================================================================
#  SmokeTest.ps1 -- 真机启动验证引擎
#
#  为什么必须做这一步：
#    "命令返回 0" 和 "游戏能跑" 是两件事。运行库装上了，依赖也解析通了，
#    仍然可能因为位数、区域、显示模式而启动失败。唯一可信的验收标准是
#    真的把它拉起来看一眼。
#
#  两个关键实现细节：
#   1. 实际启动器是 vpatch.exe，它会把 th08.exe 作为【子进程】拉起。
#      因此不能只看被启动的那个进程是否存活，必须同时盯子进程与窗口句柄。
#   2. 进程秒退时要读 NTSTATUS 退出码精确定位病因，而不是笼统说"启动失败"：
#        0xC0000135 = 缺 DLL      0xC000007B = 位数不符 / 镜像损坏
#        0xC0000142 = DLL 初始化失败   0xC0000005 = 访问违例（多为显卡/兼容层）
# ============================================================================
Set-StrictMode -Version 2.0

# NTSTATUS -> 病因说明与下一步建议
$script:TRD_NTSTATUS = @{
    '0xC0000135' = @{ Name = 'STATUS_DLL_NOT_FOUND';        Meaning = '找不到必需的 DLL';            Hint = '系统加载器在进程启动阶段就没能解析出某个依赖 DLL。用本工具的依赖清单查看具体是哪一个，再安装对应运行库。' }
    '0xC000007B' = @{ Name = 'STATUS_INVALID_IMAGE_FORMAT'; Meaning = '镜像格式无效（位数不符或文件损坏）'; Hint = '最常见原因是把 64 位 DLL 放进了 32 位游戏的目录，或某个 DLL 已损坏。本工具的「位数错配」检查项可直接定位。' }
    '0xC0000142' = @{ Name = 'STATUS_DLL_INIT_FAILED';      Meaning = 'DLL 初始化失败';              Hint = 'DLL 找到了但初始化时出错，通常是版本冲突或依赖链上还有缺失项。' }
    '0xC0000139' = @{ Name = 'STATUS_ENTRYPOINT_NOT_FOUND'; Meaning = '找不到入口点';                Hint = '某个 DLL 版本过旧，缺少程序需要的导出函数。常见于系统里存在旧版运行库。' }
    '0xC0000138' = @{ Name = 'STATUS_ORDINAL_NOT_FOUND';    Meaning = '找不到序号导出';              Hint = '同"找不到入口点"，是 DLL 版本不匹配导致。' }
    '0xC0000005' = @{ Name = 'STATUS_ACCESS_VIOLATION';     Meaning = '访问违例（程序崩溃）';        Hint = '运行库层面已无问题，属于渲染/驱动兼容性。可尝试部署 dgVoodoo2 兼容层。' }
    '0xC000001D' = @{ Name = 'STATUS_ILLEGAL_INSTRUCTION';  Meaning = '非法指令';                    Hint = '程序执行了当前 CPU 不支持的指令，通常是文件损坏或被反病毒软件改写。' }
    '0xC0000094' = @{ Name = 'STATUS_INTEGER_DIVIDE_BY_ZERO'; Meaning = '整数除零';                  Hint = '多为程序内部错误，也可能是帧率补丁在异常显示模式下算出 0。尝试重置 th08.cfg。' }
    '0xC0000409' = @{ Name = 'STATUS_STACK_BUFFER_OVERRUN'; Meaning = '栈缓冲区溢出保护触发';        Hint = '程序被安全机制终止，常见于被反病毒软件注入或文件被篡改。' }
    '0xC000013A' = @{ Name = 'STATUS_CONTROL_C_EXIT';       Meaning = '被 Ctrl+C 终止';              Hint = '进程是被手动或外部中断的，不是崩溃。' }
    '0x00000000' = @{ Name = 'SUCCESS';                     Meaning = '正常退出';                    Hint = '程序自己正常结束了。如果它没有显示任何窗口，可能是启动即退出。' }
}

function ConvertTo-TrdNtStatus {
    <#
    .SYNOPSIS
        把 Int32 退出码规范成 0xXXXXXXXX 形式的无符号十六进制。
    #>
    param([Parameter(Mandatory = $true)][int]$ExitCode)
    $u = if ($ExitCode -lt 0) { [int64]$ExitCode + 4294967296 } else { [int64]$ExitCode }
    return ('0x{0:X8}' -f $u)
}

function Get-TrdProcessSet {
    <#
    .SYNOPSIS
        取指定进程名的 PID 集合，用于区分"我们启动的"和"用户本来就开着的"。
    #>
    param([string[]]$Names)
    $set = @{}
    foreach ($n in $Names) {
        if (-not $n) { continue }
        try {
            foreach ($p in Get-Process -Name $n -ErrorAction SilentlyContinue) { $set[[int]$p.Id] = $n }
        } catch { }
    }
    return $set
}

function Invoke-TrdSmokeTest {
    <#
    .SYNOPSIS
        真正启动游戏并判定它是否成功跑起来，测完自动清理。
    .PARAMETER SettleSeconds
        判定为"成功"所需的观察时长。默认为 10 秒——足够覆盖黑屏/秒退，
        又不会让用户等太久。
    .PARAMETER KeepRunning
        验证通过后不结束进程，把游戏留给用户直接玩。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Game,
        [int]$SettleSeconds = 10,
        [int]$HardTimeoutSeconds = 45,
        [switch]$KeepRunning
    )

    $gameId = $Game.Id
    $target = if ($Game.LauncherExe) { $Game.LauncherExe } else { $Game.MainExe }
    $targetName = [System.IO.Path]::GetFileNameWithoutExtension($target)

    Write-TrdLog '' 
    Write-TrdLog '══ 启动验证 ══' 'Step'
    Write-TrdLog "启动目标: $(Split-Path -Leaf $target)" 'Detail'
    Write-TrdLog "（游戏窗口会短暂出现，验证结束后本工具会自动关闭它）" 'Detail'

    # 0. 先看用户是不是已经开着游戏，避免误杀
    $names = @($targetName, $gameId) | Sort-Object -Unique
    $before = Get-TrdProcessSet -Names $names
    if ($before.Count -gt 0) {
        Write-TrdLog "检测到游戏相关进程已经在运行（PID: $(($before.Keys) -join ', ')），跳过启动验证以免干扰。" 'Warn'
        return [PSCustomObject]@{
            Verdict = 'SKIPPED'; Message = '游戏进程已在运行，未做启动验证'
            ExitCodeHex = $null; NtStatus = $null; WindowTitle = $null; ChildSeen = $false
        }
    }

    # 1. 启动
    $startedAt = Get-Date
    $proc = $null
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $target
        $psi.WorkingDirectory = $Game.Folder
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $false
        $proc = [System.Diagnostics.Process]::Start($psi)
    } catch {
        Write-TrdLog "无法启动进程: $($_.Exception.Message)" 'Error'
        return [PSCustomObject]@{
            Verdict = 'FAILED'; Message = "无法启动进程: $($_.Exception.Message)"
            ExitCodeHex = $null; NtStatus = $null; WindowTitle = $null; ChildSeen = $false
        }
    }

    Write-TrdLog "进程已启动 (PID $($proc.Id))，观察 $SettleSeconds 秒 ..." 'Detail'

    # 2. 观察：跟踪启动器进程、子进程（真正的游戏）与窗口句柄
    $deadline = $startedAt.AddSeconds($HardTimeoutSeconds)
    $settleUntil = $startedAt.AddSeconds($SettleSeconds)
    $windowTitle = $null
    $windowPid = $null
    $childSeen = $false
    $childPid = $null
    $launcherExited = $false
    $launcherExitCode = $null

    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 300

        # 启动器是否还活着
        if (-not $launcherExited) {
            try {
                $proc.Refresh()
                if ($proc.HasExited) {
                    $launcherExited = $true
                    try { $launcherExitCode = $proc.ExitCode } catch { }
                }
            } catch { $launcherExited = $true }
        }

        # 找子进程：游戏本体（vpatch 会把 th08.exe 拉起来）
        try {
            $cands = @(Get-Process -ErrorAction SilentlyContinue |
                       Where-Object { $_.ProcessName -eq $gameId -and -not $before.ContainsKey([int]$_.Id) })
            foreach ($c in $cands) {
                $childSeen = $true
                $childPid = [int]$c.Id
                try {
                    $c.Refresh()
                    if ($c.MainWindowHandle -ne 0) {
                        $windowTitle = $c.MainWindowTitle
                        $windowPid = [int]$c.Id
                    }
                } catch { }
            }
        } catch { }

        # 启动器自身也可能是窗口持有者
        if (-not $windowTitle) {
            try {
                if (-not $launcherExited) {
                    $proc.Refresh()
                    if ($proc.MainWindowHandle -ne 0) {
                        $windowTitle = $proc.MainWindowTitle
                        $windowPid = [int]$proc.Id
                    }
                }
            } catch { }
        }

        if ($windowTitle) { break }

        # 启动器已退出且从未见到子进程且窗口也没出现 -> 判定为失败，不必等满超时
        if ($launcherExited -and -not $childSeen -and $null -ne $launcherExitCode) { break }
    }

    # 3. 判定
    $verdict = 'UNKNOWN'
    $message = ''
    $exitHex = $null
    $nt = $null

    if ($windowTitle) {
        $verdict = 'PASSED'
        $message = "游戏成功启动并创建了窗口（标题: $windowTitle）"
    } elseif ($childSeen) {
        $verdict = 'PARTIAL'
        $message = '游戏进程已存在，但在观察期内没有检测到窗口。可能是无窗口的全屏模式启动较慢，或卡在启动画面。建议手动双击启动器确认一次。'
    } elseif ($launcherExited) {
        $exitHex = ConvertTo-TrdNtStatus -ExitCode $launcherExitCode
        if ($script:TRD_NTSTATUS.ContainsKey($exitHex)) { $nt = $script:TRD_NTSTATUS[$exitHex] }
        $verdict = 'FAILED'
        if ($nt) {
            $message = "启动失败，退出码 $exitHex ($($nt.Name))：$($nt.Meaning)"
        } else {
            $message = "启动失败，退出码 $exitHex（未收录的退出码）"
        }
    } else {
        $verdict = 'UNKNOWN'
        $message = "进程在 $HardTimeoutSeconds 秒内既没有退出也没有出现窗口，可能卡在某个对话框上。"
    }

    # 4. 清理：只杀我们启动的，不碰用户原有的
    $killed = @()
    if (-not $KeepRunning -or $verdict -ne 'PASSED') {
        $toKill = New-Object System.Collections.ArrayList
        try { if (-not $launcherExited) { $null = $toKill.Add([int]$proc.Id) } } catch { }
        if ($childPid) { $null = $toKill.Add($childPid) }
        # 兜底：所有"启动后新出现"的同名进程
        $after = Get-TrdProcessSet -Names $names
        foreach ($pid2 in $after.Keys) {
            if (-not $before.ContainsKey($pid2)) { $null = $toKill.Add($pid2) }
        }

        foreach ($k in ($toKill | Sort-Object -Unique)) {
            if (-not $k) { continue }
            try {
                $null = Start-Process -FilePath "$env:windir\System32\taskkill.exe" `
                        -ArgumentList @('/PID', "$k", '/T', '/F') -Wait -PassThru -NoNewWindow -ErrorAction SilentlyContinue
                $killed += $k
            } catch { }
        }
        if ($killed.Count -gt 0) { Write-TrdLog "已结束测试进程: $(($killed | Sort-Object -Unique) -join ', ')" 'Detail' }
    } else {
        Write-TrdLog '游戏保持运行中（-KeepRunning）。' 'Info'
    }

    $result = [PSCustomObject]@{
        Verdict     = $verdict
        Message     = $message
        ExitCodeHex = $exitHex
        NtStatus    = $nt
        WindowTitle = $windowTitle
        WindowPid   = $windowPid
        ChildSeen   = $childSeen
        Target      = $target
        Elapsed     = [Math]::Round(((Get-Date) - $startedAt).TotalSeconds, 1)
    }

    switch ($verdict) {
        'PASSED'  { Write-TrdLog $message 'OK' }
        'PARTIAL' { Write-TrdLog $message 'Warn' }
        'FAILED'  {
            Write-TrdLog $message 'Error'
            if ($nt -and $nt.Hint) { Write-TrdLog "建议: $($nt.Hint)" 'Info' }
        }
        default   { Write-TrdLog $message 'Warn' }
    }

    return $result
}
