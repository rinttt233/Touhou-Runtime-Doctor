# ============================================================================
#  Check-Scripts.ps1 -- 本项目专用静态检查器
#
#  为什么需要它：
#   1. Windows PowerShell 5.1 在中文系统上会把「无 BOM 的 UTF-8」脚本按 GBK 解析，
#      导致中文乱码并破坏语法。任何编辑后都必须重新补 BOM。
#   2. PowerShell 的普通字符串不能跨行。手写长段中文说明时极易写出
#      「双引号里嵌了未转义的 "」或漏掉收尾引号，而 PowerShell 报出的行号
#      往往指在几百行之后，排查成本很高。这里用状态机直接定位到出错行。
#
#  用法： pwsh -File tools\Check-Scripts.ps1 -Root <工具根目录> [-Fix]
#  退出码：0 = 无问题，1 = 有问题
# ============================================================================
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Root,
    [switch]$Fix
)

$utf8Bom    = New-Object System.Text.UTF8Encoding($true)
$strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)

# 注意：-Include 在配合 -LiteralPath 时不可靠，这里显式按扩展名过滤。
$files = @(Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction SilentlyContinue |
           Where-Object { $_.Extension -in '.ps1', '.psm1', '.psd1' })

$problems = 0

foreach ($f in $files) {
    $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)

    # ---------- 1. BOM 检查 ----------
    if (-not $hasBom) {
        Write-Host ("[BOM ] {0} 缺少 UTF-8 BOM（PS 5.1 会按 GBK 解析，中文变乱码并破坏语法）" -f $f.Name) -ForegroundColor Yellow
        $problems++
        if ($Fix) {
            $t = $null
            try { $t = $strictUtf8.GetString($bytes) }
            catch { try { $t = [System.Text.Encoding]::GetEncoding(936).GetString($bytes) } catch { } }
            if ($null -ne $t) {
                [System.IO.File]::WriteAllText($f.FullName, $t, $utf8Bom)
                Write-Host '       -> 已补齐 BOM' -ForegroundColor DarkGray
            }
        }
    }

    # ---------- 读回文本 ----------
    $text = $null
    try { $text = $strictUtf8.GetString($bytes) } catch { }
    if ($null -eq $text) {
        try { $text = [System.Text.Encoding]::GetEncoding(936).GetString($bytes) } catch { continue }
    }
    if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
    $lines = $text -split "`r?`n"

    # ---------- 2. 引号配对状态机 ----------
    #  规则：
    #   * 反引号只在双引号字符串内是转义符；单引号字符串内反引号是普通字符。
    #   * '#' 在字符串外开始注释，注释内一律不扫描。
    #   * here-string (@' / @" 到行首的 '@ / "@) 允许跨行，整体跳过。
    $inS = $false; $inD = $false; $inHere = $null
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $L = $lines[$i]

        if ($inHere) {
            if ($L.TrimStart().StartsWith($inHere)) { $inHere = $null }
            continue
        }
        $trimmed = $L.TrimEnd()
        if ($trimmed.EndsWith('@"')) { $inHere = '"@'; continue }
        if ($trimmed.EndsWith("@'")) { $inHere = "'@"; continue }

        $s0 = $inS; $d0 = $inD
        for ($j = 0; $j -lt $L.Length; $j++) {
            $c = $L[$j]
            if ($inD -and $c -eq '`') { $j++; continue }            # 双引号内的转义
            if (-not $inS -and -not $inD -and $c -eq '#') { break } # 注释起始
            if (-not $inD -and $c -eq "'") { $inS = -not $inS; continue }
            if (-not $inS -and $c -eq '"') { $inD = -not $inD; continue }
        }
        if ($inD -and -not $d0) {
            Write-Host ("[引号] {0}:{1} 双引号未在本行闭合（普通字符串不能跨行；内层引号请改用「」）" -f $f.Name, ($i + 1)) -ForegroundColor Red
            Write-Host ("       {0}" -f $L.Trim()) -ForegroundColor DarkGray
            $problems++
        }
        if ($inS -and -not $s0) {
            Write-Host ("[引号] {0}:{1} 单引号未在本行闭合" -f $f.Name, ($i + 1)) -ForegroundColor Red
            Write-Host ("       {0}" -f $L.Trim()) -ForegroundColor DarkGray
            $problems++
        }
    }
    if ($inHere) {
        Write-Host ("[引号] {0}: here-string 未闭合（缺少 {1}）" -f $f.Name, $inHere) -ForegroundColor Red
        $problems++
    }

    # ---------- 3. 语法解析 ----------
    $err = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$null, [ref]$err)
    if ($err -and $err.Count -gt 0) {
        Write-Host ("[语法] {0} 有 {1} 处解析错误" -f $f.Name, $err.Count) -ForegroundColor Red
        $err | Select-Object -First 4 | ForEach-Object {
            Write-Host ("       行 {0}: {1}" -f $_.Extent.StartLineNumber, $_.Message) -ForegroundColor DarkGray
        }
        $problems++
    }
}

Write-Host ''
if ($problems -eq 0) {
    Write-Host ("检查通过：{0} 个脚本，未发现问题。" -f $files.Count) -ForegroundColor Green
    exit 0
} else {
    Write-Host ("发现问题 {0} 处，共扫描 {1} 个脚本。" -f $problems, $files.Count) -ForegroundColor Yellow
    if (-not $Fix) { Write-Host '提示：加 -Fix 可自动补齐 BOM。' -ForegroundColor DarkGray }
    exit 1
}
