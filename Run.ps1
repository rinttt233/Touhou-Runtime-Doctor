# ============================================================================
#  Run.ps1 -- bootstrap / launcher for Touhou Runtime Doctor
#
#  IMPORTANT: This file is intentionally PURE ASCII.
#
#  Why a bootstrap is needed at all:
#    Windows PowerShell 5.1 running on a non-English Windows decodes a
#    BOM-less UTF-8 script with the system ANSI code page (GBK/936 on Chinese
#    Windows). The engine script is full of Chinese text, so a lost BOM would
#    corrupt it and break parsing BEFORE any of our own error handling runs.
#    An ASCII-only bootstrap is immune to that, so it can always start, inspect
#    the engine file, re-attach the BOM if it went missing, and only then hand
#    off to it using a normal -File invocation (which keeps full parameter
#    binding, unlike the ScriptBlock trick).
#
#  Usage:  powershell -NoProfile -ExecutionPolicy Bypass -File Run.ps1 [-Mode ...]
# ============================================================================

$ErrorActionPreference = 'Stop'

# ---- locate ourselves ----
$here = $null
if ($PSScriptRoot) { $here = $PSScriptRoot }
elseif ($MyInvocation.MyCommand.Path) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }
else { $here = (Get-Location).Path }

$engine = Join-Path $here 'TouhouRuntimeDoctor.ps1'
if (-not (Test-Path -LiteralPath $engine)) {
    Write-Host ''
    Write-Host "[FATAL] Engine script not found:" -ForegroundColor Red
    Write-Host "        $engine" -ForegroundColor Red
    Write-Host '        Please keep Run.ps1 and TouhouRuntimeDoctor.ps1 in the same folder.' -ForegroundColor Yellow
    exit 3
}

# ---- self-heal: make sure the engine is UTF-8 WITH BOM ----
try {
    $bytes = [System.IO.File]::ReadAllBytes($engine)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)

    if (-not $hasBom) {
        Write-Host '[WARN] Engine script lost its UTF-8 BOM; repairing it now ...' -ForegroundColor Yellow
        $strict = New-Object System.Text.UTF8Encoding($false, $true)
        $text = $null
        try   { $text = $strict.GetString($bytes) }
        catch { $text = [System.Text.Encoding]::GetEncoding(936).GetString($bytes) }
        [System.IO.File]::WriteAllText($engine, $text, (New-Object System.Text.UTF8Encoding($true)))
        Write-Host '[ OK ] BOM restored.' -ForegroundColor Green
    }
} catch {
    Write-Host ('[WARN] Could not verify engine encoding: ' + $_.Exception.Message) -ForegroundColor Yellow
}

# ---- make sure lib scripts have a BOM too (the engine loads them as UTF-8) ----
try {
    $libDir = Join-Path $here 'lib'
    if (Test-Path -LiteralPath $libDir) {
        $strict = New-Object System.Text.UTF8Encoding($false, $true)
        $bomEnc = New-Object System.Text.UTF8Encoding($true)
        foreach ($f in @(Get-ChildItem -LiteralPath $libDir -File -ErrorAction SilentlyContinue |
                         Where-Object { $_.Extension -in '.ps1', '.psm1' })) {
            $b = [System.IO.File]::ReadAllBytes($f.FullName)
            if ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) { continue }
            $t = $null
            try   { $t = $strict.GetString($b) }
            catch { $t = [System.Text.Encoding]::GetEncoding(936).GetString($b) }
            [System.IO.File]::WriteAllText($f.FullName, $t, $bomEnc)
            Write-Host ('[ OK ] BOM restored: ' + $f.Name) -ForegroundColor DarkGray
        }
    }
} catch { }

# ---- hand off to the engine with a normal -File invocation ----
# Passing an array to a native command splats one argv entry per element, so
# named parameters such as -Mode survive intact.
# ---- pick the NATIVE-bit PowerShell, not merely the one we can see ----
# On 64-bit Windows a 32-bit process that asks for System32 is silently
# redirected to SysWOW64. So "Test-Path System32\...\powershell.exe" succeeds
# while actually pointing at the 32-bit host -- exactly how a 32-bit launch
# would keep handing itself to a 32-bit engine. That is not a cosmetic problem:
# in a 32-bit process every System32 file lookup and every HKLM\SOFTWARE
# registry read is redirected, so the engine would inspect SysWOW64 while
# believing it inspected System32 and report the machine wrongly.
# Sysnative is the alias (visible ONLY to 32-bit processes) for the real
# System32, so use it when we detect we are a 32-bit process on a 64-bit OS.
$psExe = $null
if ($env:PROCESSOR_ARCHITEW6432) {
    $native = Join-Path $env:SystemRoot 'Sysnative\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path -LiteralPath $native) { $psExe = $native }
}
if (-not $psExe) {
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $psExe)) { $psExe = 'powershell.exe' }
}

$forward = @(
    '-NoProfile',
    '-ExecutionPolicy', 'Bypass',
    '-File', $engine,
    '-ToolRoot', $here
) + $args

& $psExe @forward
exit $LASTEXITCODE
