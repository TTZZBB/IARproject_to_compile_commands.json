<#
.SYNOPSIS
    IAR 环境识别库：扫描已安装的 IAR、探测版本与能力、定位 .ewp 工程。
.DESCRIPTION
    由 build_compile_commands.ps1 以 dot-source 方式加载，不单独执行。
    能力探测不依赖版本号：直接跑一次 iarbuild 看它的用法文本里有没有
    -compdb / -jsondb，因此新老版本、不同产品线都能自动区分。
#>

function New-IarInfo {
    param([string]$Root)

    $build = Join-Path $Root 'common\bin\IarBuild.exe'
    $icc   = Join-Path $Root 'arm\bin\iccarm.exe'
    $asm   = Join-Path $Root 'arm\bin\iasmarm.exe'

    $ver = ''
    if ($Root -match 'Embedded Workbench\s+([0-9][0-9.]*)\s*$') { $ver = $Matches[1] }
    if (-not $ver) {
        try { $ver = (Get-Item -LiteralPath $build).VersionInfo.FileVersion } catch { $ver = '' }
    }

    [pscustomobject]@{
        Root     = $Root
        Version  = $ver
        IarBuild = $build
        IccArm   = $(if (Test-Path -LiteralPath $icc) { $icc } else { $null })
        IasmArm  = $(if (Test-Path -LiteralPath $asm) { $asm } else { $null })
        CompDb   = $false
        JsonDb   = $false
    }
}

function Get-IarCapabilities {
    param([string]$IarBuild)

    $res = [pscustomobject]@{ CompDb = $false; JsonDb = $false }
    if (-not $IarBuild -or -not (Test-Path -LiteralPath $IarBuild)) { return $res }

    # 不带参数运行会打印用法；用文本判断比猜版本号可靠
    try { $txt = (& $IarBuild 2>&1 | Out-String) } catch { return $res }
    if ($txt -match '-compdb') { $res.CompDb = $true }
    if ($txt -match '-jsondb') { $res.JsonDb = $true }
    return $res
}

function Get-IarInstallations {
    param([switch]$Probe)

    $bases = @()
    if (${env:ProgramFiles(x86)}) { $bases += (Join-Path ${env:ProgramFiles(x86)} 'IAR Systems') }
    if ($env:ProgramFiles)        { $bases += (Join-Path $env:ProgramFiles 'IAR Systems') }

    $roots = @()
    foreach ($b in $bases) {
        if (-not (Test-Path -LiteralPath $b)) { continue }
        $dirs = Get-ChildItem -LiteralPath $b -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like 'Embedded Workbench*' }
        foreach ($d in $dirs) {
            if (Test-Path -LiteralPath (Join-Path $d.FullName 'common\bin\IarBuild.exe')) {
                $roots += $d.FullName
            }
        }
    }

    $out = @()
    foreach ($r in ($roots | Sort-Object -Unique)) {
        $info = New-IarInfo -Root $r
        if ($Probe) {
            $cap = Get-IarCapabilities -IarBuild $info.IarBuild
            $info.CompDb = $cap.CompDb
            $info.JsonDb = $cap.JsonDb
        }
        $out += $info
    }
    return $out
}

# 允许 -IarRoot 指向安装根、common\bin、或 IarBuild.exe 本身
function Resolve-IarRoot {
    param([string]$Path)

    if (-not $Path) { return $null }
    $p = $Path.TrimEnd('\')
    if (-not (Test-Path -LiteralPath $p)) { return $null }

    if (-not (Test-Path -LiteralPath $p -PathType Container)) { $p = Split-Path -Parent $p }
    if ((Split-Path -Leaf $p) -eq 'bin') { $p = Split-Path -Parent (Split-Path -Parent $p) }

    if (Test-Path -LiteralPath (Join-Path $p 'common\bin\IarBuild.exe')) {
        return (New-IarInfo -Root $p)
    }
    return $null
}

function Get-EwpSavedVersion {
    param([string]$Ewp)

    try {
        $txt = [System.IO.File]::ReadAllText($Ewp, [System.Text.Encoding]::Default)
        $m = [regex]::Match($txt, 'OGLastSavedByProductVersion</name>\s*<state>([0-9][0-9.]*)</state>')
        if ($m.Success) { return $m.Groups[1].Value }
    } catch { }
    return ''
}

function Find-EwpProjects {
    param([string]$Root, [int]$Depth = 4)

    $all = @()
    if (-not (Test-Path -LiteralPath $Root)) { return $all }

    # 优先只看 <工作区根>\Project\，找不到再全工作区浅层搜索
    $pri = Join-Path $Root 'Project'
    if (Test-Path -LiteralPath $pri) {
        $all += Get-ChildItem -LiteralPath $pri -Filter *.ewp -Recurse -File -ErrorAction SilentlyContinue
    }
    $all += Get-ChildItem -LiteralPath $Root -Filter *.ewp -Recurse -Depth $Depth -File -ErrorAction SilentlyContinue

    return @($all | Sort-Object FullName -Unique)
}

function Select-IarInstall {
    param([object[]]$Installs, [string]$SavedVersion = '')

    $list = @($Installs | Where-Object { $_ })
    if ($list.Count -eq 0) { return $null }

    # 工程由哪个版本保存，就优先用同版本（7.5x 的工程优先用 7.5）。
    # IAR 的产品版本写作 7.50.x，安装目录却是 7.5，所以按数值比较（7.50 == 7.5）。
    if ($SavedVersion) {
        $parts = $SavedVersion.Split('.')
        if ($parts.Count -ge 2) {
            $mm = $null
            try { $mm = [double]($parts[0] + '.' + $parts[1]) } catch { $mm = $null }
            if ($null -ne $mm) {
                foreach ($i in $list) {
                    $iv = $null
                    try { $iv = [double]$i.Version } catch { $iv = $null }
                    if ($null -ne $iv -and [math]::Abs($iv - $mm) -lt 0.0001) { return $i }
                }
            }
        }
    }

    # 否则取版本号最大的（按 [version] 比较，9.10 > 9.7）
    $best = $null
    $bestV = $null
    foreach ($i in $list) {
        $v = $null
        if ($i.Version) { try { $v = [version]$i.Version } catch { $v = $null } }
        if ($null -eq $v) { continue }
        if ($null -eq $bestV -or $v -gt $bestV) { $bestV = $v; $best = $i }
    }
    if ($best) { return $best }
    return $list[0]
}

function Get-IarCapabilityText {
    param($Info)

    $caps = @()
    if ($Info.CompDb) { $caps += '-compdb' }
    if ($Info.JsonDb) { $caps += '-jsondb' }
    if ($caps.Count -eq 0) { return '无（走日志解析）' }
    return ($caps -join ' / ')
}
