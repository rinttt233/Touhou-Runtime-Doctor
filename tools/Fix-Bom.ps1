# ============================================================================
#  Fix-Bom.ps1 -- force UTF-8 with BOM on every PowerShell script under -Root
#
#  IMPORTANT: This file is intentionally written in PURE ASCII.
#  Reason: Windows PowerShell 5.1 running on a non-English system decodes a
#  BOM-less UTF-8 script using the system ANSI code page (GBK/936 on Chinese
#  Windows), which corrupts any non-ASCII source text and can break parsing.
#  An ASCII-only file is immune to that problem, so this fixer can always run
#  even when every other script in the project is currently broken.
#
#  Usage: pwsh -File tools\Fix-Bom.ps1 -Root <tool-root>
# ============================================================================
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Root
)

$utf8Bom = New-Object System.Text.UTF8Encoding($true)
$strict  = New-Object System.Text.UTF8Encoding($false, $true)

$changed = 0
$scanned = 0

$files = @(Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction SilentlyContinue |
           Where-Object { $_.Extension -in '.ps1', '.psm1', '.psd1' })

foreach ($f in $files) {
    $scanned++
    $b = [System.IO.File]::ReadAllBytes($f.FullName)

    if ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) { continue }

    $t = $null
    try {
        $t = $strict.GetString($b)                       # valid UTF-8 -> trust it
    } catch {
        try { $t = [System.Text.Encoding]::GetEncoding(936).GetString($b) } catch { continue }
    }

    [System.IO.File]::WriteAllText($f.FullName, $t, $utf8Bom)
    $changed++
    Write-Host ("  [BOM+] " + $f.Name)
}

Write-Host ("Fix-Bom: scanned $scanned, converted $changed.")
