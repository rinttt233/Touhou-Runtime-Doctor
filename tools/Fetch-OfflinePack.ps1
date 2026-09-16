# ============================================================================
#  Fetch-OfflinePack.ps1 -- 离线载荷获取器
#
#  用途：在一台【能联网】的机器上运行一次，把工具需要的运行库与组件
#        抓到 offline\ 目录，然后整个文件夹拷到离线的目标机器上使用。
#
#  设计要点（都是踩过坑之后定下来的）：
#   1. 完全由 offline\packages.json 驱动，包地址写数据里不写代码里。
#   2. 先下到 .part 临时文件，校验通过才改名 —— 中途断网不会留下一个
#      看起来正常、其实是半截的文件（这类文件装到系统里会很难查）。
#   3. SHA256「自封」：清单里没写哈希的包，下载后自动算出并回写清单。
#      这样第一次抓完，清单就变成可信基线，之后每次都能校验。
#   4. 微软/第三方二进制额外做 Authenticode 校验，签名链不可信就告警。
#   5. GitHub 类来源运行时查 API 取最新发布资产，不把版本号写死在 URL 里
#      （写死迟早会 404）。
#   6. 兼容 PowerShell 3.0 / Windows 7：不使用 PS5 专有 cmdlet，
#      并显式启用 TLS 1.2（Win7 默认可能是 TLS 1.0，直连 HTTPS 会失败）。
#
#  用法：
#     powershell -ExecutionPolicy Bypass -File tools\Fetch-OfflinePack.ps1 -List
#     powershell -ExecutionPolicy Bypass -File tools\Fetch-OfflinePack.ps1 -All
#     powershell -ExecutionPolicy Bypass -File tools\Fetch-OfflinePack.ps1 -Only VC2010_X86,TOOL_DGVOODOO2
#     powershell -ExecutionPolicy Bypass -File tools\Fetch-OfflinePack.ps1 -VerifyOnly
#     powershell -ExecutionPolicy Bypass -File tools\Fetch-OfflinePack.ps1 -All -Force
# ============================================================================
#Requires -Version 3.0
[CmdletBinding()]
param(
    [string]$ToolRoot,
    [string[]]$Only,
    # -All 是显式的"处理全部缺失包"。不加任何选择参数时行为相同，
    # 保留它是因为文档与习惯用法里都会写 -All。
    [switch]$All,
    [switch]$List,
    [switch]$VerifyOnly,
    [switch]$Force,
    [switch]$ExtractDirectX,
    [string]$Proxy,
    [int]$TimeoutSec = 900
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
#  0. 让老系统能连上现代 HTTPS
# ---------------------------------------------------------------------------
# Windows 7 出厂默认可能只有 TLS 1.0，而 GitHub 与微软下载站早已要求 1.2。
# 不设置的话表现为"服务器无响应/基础连接已关闭"，很难联想到 TLS。
try {
    $proto = [System.Net.SecurityProtocolType]::Tls12
    if ([Enum]::GetNames([System.Net.SecurityProtocolType]) -contains 'Tls13') {
        $proto = $proto -bor [System.Net.SecurityProtocolType]::Tls13
    }
    [System.Net.ServicePointManager]::SecurityProtocol = $proto
} catch {
    Write-Host '  [警告] 无法设置 TLS 1.2，老系统上可能连不上下载站。' -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
#  1. 定位与工具函数
# ---------------------------------------------------------------------------
if (-not $ToolRoot) {
    if ($PSScriptRoot) { $ToolRoot = Split-Path -Parent $PSScriptRoot }
    elseif ($MyInvocation.MyCommand.Path) { $ToolRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path) }
    else { $ToolRoot = (Get-Location).Path }
}
$OfflineRoot = Join-Path $ToolRoot 'offline'
$ManifestPath = Join-Path $OfflineRoot 'packages.json'

function Write-Head {
    param([string]$Text)
    Write-Host ''
    Write-Host ('=' * 78) -ForegroundColor DarkCyan
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host ('=' * 78) -ForegroundColor DarkCyan
}
function Write-Item {
    param([string]$Tag, [string]$Text, [string]$Color = 'Gray')
    Write-Host ('  [' + $Tag + '] ' + $Text) -ForegroundColor $Color
}

function Get-Sha256 {
    <#
    .SYNOPSIS
        自己算 SHA256，不依赖 Get-FileHash（那是 PowerShell 4.0 才有的）。
        本脚本刻意不 dot-source lib\Common.ps1：抓取器要能在工具库
        本身出问题时依然可用。
    #>
    param([Parameter(Mandatory = $true)][string]$Path)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $fs = $null
    try {
        $fs = [System.IO.File]::OpenRead($Path)
        return ([BitConverter]::ToString($sha.ComputeHash($fs)) -replace '-', '')
    } finally {
        if ($fs) { $fs.Close() }
        $sha.Dispose()
    }
}

function Test-IsBinary {
    param([string]$Name)
    return ($Name -match '(?i)\.(exe|msi|dll|cab)$')
}

function Get-AuthenticodeInfo {
    <#
    .SYNOPSIS
        返回签名状态与签名者。老系统没有 Get-AuthenticodeSignature 时返回 null。
    #>
    param([string]$Path)
    if (-not (Get-Command -Name 'Get-AuthenticodeSignature' -ErrorAction SilentlyContinue)) { return $null }
    try {
        $sg = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
        $signer = ''
        if ($sg.SignerCertificate) { $signer = [string]$sg.SignerCertificate.Subject }
        return [PSCustomObject]@{ Status = [string]$sg.Status; Signer = $signer }
    } catch {
        return $null
    }
}

function Resolve-GitHubAsset {
    <#
    .SYNOPSIS
        查 GitHub 最新发布，按正则挑出资产下载地址。
    .DESCRIPTION
        把版本号写死在 URL 里迟早会 404，所以每次运行时查 API。
        GitHub API 要求带 User-Agent，不带会被拒。
    #>
    param([string]$Repo, [string]$Pattern, [string]$Proxy)

    $api = "https://api.github.com/repos/$Repo/releases/latest"
    $args = @{
        Uri         = $api
        UserAgent   = 'TouhouRuntimeDoctor-FetchOfflinePack'
        TimeoutSec  = 60
        ErrorAction = 'Stop'
    }
    if ($Proxy) { $args['Proxy'] = $Proxy }
    $rel = Invoke-RestMethod @args
    if (-not $rel -or -not $rel.assets) { return $null }
    foreach ($a in $rel.assets) {
        if ($a.name -match $Pattern) {
            return [PSCustomObject]@{ Url = $a.browser_download_url; Name = $a.name; Size = [int64]$a.size; Tag = [string]$rel.tag_name }
        }
    }
    return $null
}

function Invoke-DownloadFile {
    <#
    .SYNOPSIS
        下载到 .part 再改名，中途失败不留半截文件。
    .OUTPUTS
        PSCustomObject: Ok, Path, Bytes, Message
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Destination,
        [string]$Proxy,
        [int]$TimeoutSec = 900
    )

    $part = $Destination + '.part'
    if (Test-Path -LiteralPath $part) { Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue }

    $wc = New-Object System.Net.WebClient
    $wc.Headers.Add('User-Agent', 'TouhouRuntimeDoctor-FetchOfflinePack')
    if ($Proxy) {
        $wc.Proxy = New-Object System.Net.WebProxy($Proxy, $true)
    }
    $script:lastPct = -1
    $handler = {
        param($sender, $e)
        if ($e.TotalBytesToReceive -gt 0) {
            $pct = [int](100 * $e.BytesReceived / $e.TotalBytesToReceive)
            if ($pct -ge $script:lastPct + 10) {
                $script:lastPct = $pct
                Write-Host ("      {0,3}%  ({1:N1} / {2:N1} MB)" -f $pct, ($e.BytesReceived / 1MB), ($e.TotalBytesToReceive / 1MB)) -ForegroundColor DarkGray
            }
        }
    }
    $wc.add_DownloadProgressChanged($handler)
    try {
        $wc.DownloadFile($Url, $part)
        $len = (Get-Item -LiteralPath $part).Length
        Move-Item -LiteralPath $part -Destination $Destination -Force
        return [PSCustomObject]@{ Ok = $true; Path = $Destination; Bytes = $len; Message = '' }
    } catch {
        if (Test-Path -LiteralPath $part) { Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue }
        return [PSCustomObject]@{ Ok = $false; Path = $null; Bytes = 0; Message = $_.Exception.Message }
    } finally {
        $wc.Dispose()
    }
}

# ---------------------------------------------------------------------------
#  2. 读清单
# ---------------------------------------------------------------------------
if (-not (Test-Path -LiteralPath $OfflineRoot)) {
    $null = New-Item -ItemType Directory -Path $OfflineRoot -Force
}
if (-not (Test-Path -LiteralPath $ManifestPath)) {
    Write-Host ''
    Write-Host "  [致命] 找不到载荷清单: $ManifestPath" -ForegroundColor Red
    Write-Host '         清单是抓取的唯一依据，请确认 offline\packages.json 存在。' -ForegroundColor Yellow
    exit 3
}
$manifest = [System.IO.File]::ReadAllText($ManifestPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
$packages = @($manifest.Packages)

# ---------------------------------------------------------------------------
#  3. 逐包评估现状
# ---------------------------------------------------------------------------
function Select-PackageFile {
    <# 在载荷目录里按清单的候选名找文件（与主程序 Find-TrdOfflinePackage 同规则） #>
    param($Package)
    $cands = New-Object System.Collections.ArrayList
    foreach ($prop in @('Files', 'File', 'ZipGlobs')) {
        if ($Package.PSObject.Properties.Name -contains $prop -and $Package.$prop) {
            foreach ($x in @($Package.$prop)) { if ($x) { $null = $cands.Add($x) } }
        }
    }
    foreach ($c in $cands) {
        if ($c -match '\*' -or $c -match '\?') {
            try {
                $f = Get-ChildItem -Path (Join-Path $OfflineRoot $c) -File -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($f) { return $f.FullName }
            } catch { }
        } else {
            $p = Join-Path $OfflineRoot $c
            if (Test-Path -LiteralPath $p -PathType Leaf) { return $p }
        }
    }
    return $null
}

function Get-PackageState {
    param($Package)
    $path = Select-PackageFile -Package $Package
    $st = [PSCustomObject]@{
        Id = $Package.Id; Title = $Package.Title; Path = $path
        Present = [bool]$path; HashOk = $null; Actual = ''; SizeMB = 0
    }
    if ($path) {
        $st.SizeMB = [math]::Round((Get-Item -LiteralPath $path).Length / 1MB, 2)
        $expected = ''
        if ($Package.PSObject.Properties.Name -contains 'Sha256') { $expected = [string]$Package.Sha256 }
        if ($expected) {
            try {
                $st.Actual = Get-Sha256 -Path $path
                $st.HashOk = ($st.Actual -ieq $expected)
            } catch { $st.HashOk = $null }
        }
    }
    return $st
}

$states = @{}
foreach ($p in $packages) { $states[$p.Id] = Get-PackageState -Package $p }

# ---------------------------------------------------------------------------
#  4. -List：只报告现状与将要做的事
# ---------------------------------------------------------------------------
if ($List -or $VerifyOnly) {
    if ($VerifyOnly) { Write-Head '校验现有载荷' } else { Write-Head '载荷现状' }
    $okN = 0; $missingN = 0; $badN = 0; $noUrlN = 0
    foreach ($p in $packages) {
        $s = $states[$p.Id]
        $hasUrl = (@($p.Url).Count -gt 0) -or ($p.PSObject.Properties.Name -contains 'Repo')
        if (-not $s.Present) {
            $missingN++
            $tag = '缺失'; $col = 'Yellow'
            $how = if ($hasUrl) { '可自动抓取' } else { $noUrlN++; '需手工提供' }
            Write-Item $tag ("{0,-20} {1}  ({2})" -f $p.Id, $p.Title, $how) $col
        } elseif ($s.HashOk -eq $true) {
            $okN++
            Write-Item '完好' ("{0,-20} {1,8:N2} MB  SHA256 与清单一致" -f $p.Id, $s.SizeMB) 'Green'
        } elseif ($s.HashOk -eq $false) {
            $badN++
            Write-Item '不符' ("{0,-20} {1,8:N2} MB  实际 {2}（清单 {3}）" -f $p.Id, $s.SizeMB, $s.Actual.Substring(0, 12), ([string]$p.Sha256).Substring(0, 12)) 'Red'
        } else {
            $okN++
            Write-Item '在位' ("{0,-20} {1,8:N2} MB  清单未记录哈希（可用 -Force 重下以自封）" -f $p.Id, $s.SizeMB) 'DarkGray'
        }
    }
    Write-Host ''
    Write-Host ("  完好 {0} / 缺失 {1} / 哈希不符 {2}" -f $okN, $missingN, $badN) -ForegroundColor Cyan
    if ($noUrlN -gt 0) {
        Write-Host ("  其中 {0} 个包没有可用下载地址，需手工提供（见清单里的 Note）" -f $noUrlN) -ForegroundColor Yellow
    }
    if ($List) { exit 0 }
    if ($badN -gt 0) { exit 2 }
    exit 0
}

# ---------------------------------------------------------------------------
#  5. 筛选本次要处理的包
# ---------------------------------------------------------------------------
$targets = @()
foreach ($p in $packages) {
    if ($Only -and $Only.Count -gt 0) {
        if ($Only -notcontains $p.Id) { continue }
    }
    $s = $states[$p.Id]
    if ($s.Present -and $s.HashOk -eq $true -and -not $Force) { continue }
    $targets += $p
}

Write-Head '离线载荷获取器'
Write-Item '..' "工具目录  : $ToolRoot"
Write-Item '..' "载荷目录  : $OfflineRoot"
Write-Item '..' "清单      : $($packages.Count) 个包，本次需要处理 $($targets.Count) 个"

if ($targets.Count -eq 0) {
    Write-Host ''
    Write-Host '  所有包都已就位且哈希一致，无需下载。' -ForegroundColor Green
    # 注意：不能在这里无条件 exit。-ExtractDirectX 是独立的后续动作，
    # 载荷齐全时它恰恰是最该执行的时候；早期版本在此直接退出，
    # 导致"下载完就再也解不开包"。
    if (-not $Force -and -not $ExtractDirectX) { exit 0 }
}

# ---------------------------------------------------------------------------
#  6. 逐个抓取
# ---------------------------------------------------------------------------
$script:manifestDirty = $false
$results = New-Object System.Collections.ArrayList

foreach ($p in $targets) {
    Write-Host ''
    Write-Item '>>' $p.Id 'Cyan'

    # 决定目标路径：优先用 Files 的第一条相对路径，保持目录结构清晰
    $rel = $null
    if ($p.PSObject.Properties.Name -contains 'Files' -and $p.Files) {
        $first = @($p.Files) | Where-Object { $_ -notmatch '\*' } | Select-Object -First 1
        if ($first) { $rel = $first }
    }
    if (-not $rel) { $rel = 'Tools\' + $p.Id + '.zip' }
    $dest = Join-Path $OfflineRoot $rel
    $destDir = Split-Path -Parent $dest
    if (-not (Test-Path -LiteralPath $destDir)) { $null = New-Item -ItemType Directory -Path $destDir -Force }

    # 解析下载地址：github 类先查 API
    $url = $null; $remoteSize = 0; $resolvedFrom = ''
    if ($p.PSObject.Properties.Name -contains 'Repo' -and $p.Repo) {
        Write-Item '..' "查询 GitHub 最新发布: $($p.Repo)" 'Gray'
        try {
            $asset = Resolve-GitHubAsset -Repo $p.Repo -Pattern $p.AssetPattern -Proxy $Proxy
            if ($asset) {
                $url = $asset.Url; $remoteSize = $asset.Size
                $resolvedFrom = "$($p.Repo) $($asset.Tag) / $($asset.Name)"
                Write-Item 'OK' "最新资产: $($asset.Name)（$([math]::Round($asset.Size/1MB,2)) MB）" 'Green'
            } else {
                Write-Item '!!' "最新发布里没有匹配 $($p.AssetPattern) 的资产" 'Yellow'
            }
        } catch {
            Write-Item '!!' "查询失败: $($_.Exception.Message)" 'Yellow'
        }
        # GitHub 失败时退回清单里的 Url（如果有）
        if (-not $url -and $p.PSObject.Properties.Name -contains 'Url' -and @($p.Url).Count -gt 0) {
            $url = @($p.Url)[0]
        }
    } else {
        $urls = @()
        if ($p.PSObject.Properties.Name -contains 'Url') { $urls = @($p.Url) }
        if ($urls.Count -gt 0) { $url = $urls[0] }
    }

    if (-not $url) {
        $note = ''
        if ($p.PSObject.Properties.Name -contains 'Note') { $note = [string]$p.Note }
        Write-Item '--' '没有可用的下载地址，跳过。' 'Yellow'
        if ($note) { Write-Item '  ' $note 'DarkGray' }
        Write-Item '  ' "请手工获取后放到: $dest" 'DarkGray'
        $null = $results.Add([PSCustomObject]@{ Id = $p.Id; Ok = $false; Kind = 'no-url'; Message = '无下载地址，需手工提供' })
        continue
    }

    Write-Item '..' "下载: $url" 'Gray'
    if ($resolvedFrom) { Write-Item '..' "来源: $resolvedFrom" 'DarkGray' }

    $dl = Invoke-DownloadFile -Url $url -Destination $dest -Proxy $Proxy -TimeoutSec $TimeoutSec
    if (-not $dl.Ok) {
        Write-Item '!!' "下载失败: $($dl.Message)" 'Red'
        $null = $results.Add([PSCustomObject]@{ Id = $p.Id; Ok = $false; Kind = 'download'; Message = $dl.Message })
        continue
    }

    # 大小合理性：声明了 SizeMB 就做 20% 容差比对，能抓出被门户插页、
    # 被代理截断、下成 HTML 错误页等"看起来成功其实不对"的情况
    $actualMB = [math]::Round($dl.Bytes / 1MB, 2)
    if ($p.PSObject.Properties.Name -contains 'SizeMB' -and [double]$p.SizeMB -gt 0) {
        $declared = [double]$p.SizeMB
        $lo = $declared * 0.8; $hi = $declared * 1.2
        if ($actualMB -lt $lo -or $actualMB -gt $hi) {
            # GitHub 的包会随版本变化，尺寸不比对的只有这一类
            if ($p.PSObject.Properties.Name -notcontains 'Repo') {
                Write-Item '!!' ("大小异常：实际 {0} MB，清单声明 {1} MB（容差 ±20%）" -f $actualMB, $declared) 'Red'
                $null = $results.Add([PSCustomObject]@{ Id = $p.Id; Ok = $false; Kind = 'size'; Message = "大小异常 $actualMB MB != $declared MB" })
                continue
            }
        }
    }
    Write-Item 'OK' ("已下载 {0} MB" -f $actualMB) 'Green'

    # SHA256：清单有就校验，没有就自封（写回清单）
    $expected = ''
    if ($p.PSObject.Properties.Name -contains 'Sha256') { $expected = [string]$p.Sha256 }
    $actual = Get-Sha256 -Path $dest
    if ($expected) {
        if ($actual -ieq $expected) {
            Write-Item 'OK' "SHA256 与清单一致: $($actual.Substring(0,16))..." 'Green'
        } else {
            Write-Item '!!' "SHA256 不符！清单 $($expected.Substring(0,16))... 实际 $($actual.Substring(0,16))..." 'Red'
            $null = $results.Add([PSCustomObject]@{ Id = $p.Id; Ok = $false; Kind = 'hash'; Message = 'SHA256 不符' })
            continue
        }
    } else {
        $p.Sha256 = $actual
        $script:manifestDirty = $true
        Write-Item 'OK' "SHA256 已自封并写回清单: $($actual.Substring(0,16))..." 'Green'
    }

    # 签名校验：只做告警，不阻断（有些合法工具就是没签名）
    if (Test-IsBinary -Name $dest) {
        $sg = Get-AuthenticodeInfo -Path $dest
        if ($sg) {
            if ($sg.Status -eq 'Valid') {
                $who = if ($sg.Signer -match 'O=([^,]+)') { $Matches[1] } else { $sg.Signer }
                Write-Item 'OK' "数字签名有效（$who）" 'Green'
            } else {
                Write-Item '!!' "数字签名状态: $($sg.Status)（未通过微软信任链校验，请自行确认来源）" 'Yellow'
            }
        }
    }

    $null = $results.Add([PSCustomObject]@{ Id = $p.Id; Ok = $true; Kind = 'ok'; Message = "$actualMB MB" })
}

# ---------------------------------------------------------------------------
#  7. 需要时解包 DirectX 运行库
# ---------------------------------------------------------------------------
if ($ExtractDirectX) {
    $dxPkg = $packages | Where-Object { $_.Id -eq 'DX9_REDIST_JUN2010' } | Select-Object -First 1
    if ($dxPkg) {
        Write-Head '解包 DirectX 运行库'
        $exe = Select-PackageFile -Package $dxPkg
        if (-not $exe) {
            Write-Item '--' '没有找到 DirectX 运行库文件，跳过。' 'Yellow'
        } else {
            $outDir = Join-Path $OfflineRoot 'DirectX\dxsetup'
            if (Test-Path -LiteralPath $outDir) { Remove-Item -LiteralPath $outDir -Recurse -Force -ErrorAction SilentlyContinue }
            $null = New-Item -ItemType Directory -Path $outDir -Force
            Write-Item '..' "目标目录: $outDir" 'Gray'

            # 校验函数：真正的 DXSETUP.exe 只有约 500 KB。
            # 如果解出来的同名文件有几十 MB，那它是归档本身而不是安装器。
            # 必须拦下这种"看起来成功"的失败 —— 否则后面会去执行一个
            # 其实是压缩包的"安装器"，行为完全不可预期。
            $verify = {
                param([string]$Dir)
                $s = Get-ChildItem -LiteralPath $Dir -Recurse -Filter 'DXSETUP.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
                if (-not $s) { return $null }
                if ($s.Length -gt 20MB) { return $null }
                return $s
            }

            # 首选官方自解压开关，不需要任何第三方工具。
            Write-Item '..' '解包方式一：官方自解压 /Q /T:<目录>' 'Gray'
            $setup = $null
            try {
                $p = Start-Process -FilePath $exe -ArgumentList '/Q', "/T:$outDir" -Wait -PassThru `
                        -WorkingDirectory (Split-Path -Parent $exe)
                Write-Item '..' "自解压退出码: $($p.ExitCode)" 'DarkGray'
            } catch {
                Write-Item '!!' "自解压调用失败: $($_.Exception.Message)" 'Yellow'
            }
            # 自解压器退出后可能还有一小段时间在落盘。这里轮询等待，
            # 否则会因为"抢跑"误判失败，白白退回到需要第三方工具的方案 ——
            # 实测就是这样：官方方式其实成功了，却仍去调了 Bandizip。
            for ($i = 0; $i -lt 30; $i++) {
                $setup = & $verify $outDir
                if ($setup) { break }
                Start-Sleep -Seconds 1
            }

            # 兜底：Bandizip
            if (-not $setup) {
                Write-Item '..' '解包方式二：Bandizip' 'Gray'
                $bzip = @(
                    (Join-Path $env:ProgramFiles 'Bandizip\bz.exe'),
                    (Join-Path ${env:ProgramFiles(x86)} 'Bandizip\bz.exe'),
                    'C:\Program Files\Bandizip\bz.exe'
                ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
                if ($bzip) {
                    if (Test-Path -LiteralPath $outDir) { Remove-Item -LiteralPath $outDir -Recurse -Force -ErrorAction SilentlyContinue }
                    $null = New-Item -ItemType Directory -Path $outDir -Force
                    & $bzip x -y ("-o:$outDir") $exe | Out-Null
                    $setup = & $verify $outDir
                } else {
                    Write-Item '--' '未找到 Bandizip（bz.exe），跳过兜底方案。' 'Yellow'
                }
            }

            if ($setup) {
                $n = @(Get-ChildItem -LiteralPath $outDir -File).Count
                Write-Item 'OK' ("已解出 DXSETUP.exe（{0:N1} KB）及 {1} 个文件" -f ($setup.Length / 1KB), $n) 'Green'
                Write-Item '..' '主程序会优先使用这个已解包目录，无需再解一次。' 'DarkGray'
            } else {
                Write-Item '!!' '解包未得到有效的 DXSETUP.exe。' 'Yellow'
                Write-Item '  ' '不影响修复：offline\DX_DLL\x86|x64 的逐组件部署路径仍然可用。' 'DarkGray'
                Write-Item '  ' '也可手工解包到 offline\DirectX\dxsetup\ 使其包含 DXSETUP.exe。' 'DarkGray'
            }
        }
    }
}

# ---------------------------------------------------------------------------
#  8. 回写清单（SHA256 自封）
# ---------------------------------------------------------------------------
if ($script:manifestDirty) {
    $out = [ordered]@{ Version = $manifest.Version; Packages = @($packages) }
    $json = $out | ConvertTo-Json -Depth 8
    [System.IO.File]::WriteAllText($ManifestPath, $json, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host ''
    Write-Item 'OK' '清单已更新（新下载的包写入了 SHA256，之后每次都会校验）' 'Green'
}

# ---------------------------------------------------------------------------
#  9. 汇总
# ---------------------------------------------------------------------------
Write-Head '结果汇总'
$okCount = @($results | Where-Object { $_.Ok }).Count
$badList = @($results | Where-Object { -not $_.Ok })
foreach ($r in $results) {
    $col = if ($r.Ok) { 'Green' } else { 'Yellow' }
    Write-Item $(if ($r.Ok) { 'OK' } else { '--' }) ("{0,-20} {1}" -f $r.Id, $r.Message) $col
}
Write-Host ''
Write-Host ("  成功 {0} / 待处理 {1}" -f $okCount, $badList.Count) -ForegroundColor Cyan

# 提示还没处理的既有缺口
$stillMissing = @()
foreach ($p in $packages) {
    $s = Get-PackageState -Package $p
    if (-not $s.Present) { $stillMissing += $p.Id }
}
if ($stillMissing.Count -gt 0) {
    Write-Host ("  仍有 {0} 个包未就位: {1}" -f $stillMissing.Count, ($stillMissing -join ', ')) -ForegroundColor Yellow
}
Write-Host ''
Write-Host '  下一步：把整个工具文件夹拷到离线的目标机器，双击「自检.bat」再双击「一键修复.bat」。' -ForegroundColor Gray

if ($badList.Count -gt 0) { exit 1 }
exit 0
