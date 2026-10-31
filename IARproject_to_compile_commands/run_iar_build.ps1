<#
.SYNOPSIS
    运行 IarBuild 并实时显示编译进度，同时把完整日志写入文件。

.DESCRIPTION
    build_compile_commands.bat 的 [1/2] 步骤调用本脚本。
    IarBuild 的原始输出（-log all，含每条完整命令行）仍然逐字节写入日志，
    控制台只刷新一行进度：已编译数 / 总数、百分比、正在编译的文件、已用时间。
    这样全量编译大工程时，不会因为界面长时间没有输出而误以为脚本卡死。

.PARAMETER IarBuild
    IarBuild.exe 的绝对路径。

.PARAMETER Ewp
    .ewp 工程文件路径。

.PARAMETER Config
    构建配置名，例如 Debug。

.PARAMETER LogFile
    完整构建日志的输出路径，供 gen_compile_commands.ps1 解析。

.PARAMETER Total
    编译单元总数；省略时从 .ewp 的 <file> 节点统计。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$IarBuild,
    [Parameter(Mandatory = $true)][string]$Ewp,
    [string]$Config = 'Debug',
    [string]$LogFile = (Join-Path $env:TEMP 'iar75_build.log'),
    [int]$Total = 0
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $IarBuild)) { throw "找不到 IarBuild.exe: $IarBuild" }
if (-not (Test-Path -LiteralPath $Ewp))     { throw "找不到工程文件: $Ewp" }

# 编译单元总数：.ewp 里登记的 .c/.cpp/.s，用于显示 n/总数
if ($Total -le 0) {
    try {
        [xml]$xml = Get-Content -LiteralPath $Ewp -Raw
        $Total = @($xml.SelectNodes('//file') | Where-Object { $_.InnerText -match '\.(c|cpp|cc|s|asm)$' }).Count
    } catch {
        $Total = 0
    }
}

$logDir = Split-Path -Parent $LogFile
if ($logDir -and -not (Test-Path -LiteralPath $logDir)) {
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
}
Remove-Item -LiteralPath $LogFile -Force -ErrorAction SilentlyContinue
$errFile = $LogFile + '.err'
Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue

# 按控制台显示宽度补空格（中文占 2 列），避免进度行折行
function Pad-Visual {
    param([string]$Text, [int]$Width)
    $w = 0
    foreach ($ch in $Text.ToCharArray()) { if ([int]$ch -gt 12288) { $w += 2 } else { $w += 1 } }
    if ($w -lt $Width) { return $Text + (' ' * ($Width - $w)) }
    return $Text
}

# 增量读取日志：只消费到最后一个换行，避免读到写了一半的行
function Read-LogChunk {
    param([string]$Path, [long]$Offset, [switch]$Partial)
    $res = @{ Text = ''; Offset = $Offset }
    if (-not (Test-Path -LiteralPath $Path)) { return $res }
    $fs = $null
    try {
        $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $len = $fs.Length
        if ($len -gt $Offset) {
            $fs.Position = $Offset
            $buf = New-Object byte[] ($len - $Offset)
            $read = $fs.Read($buf, 0, $buf.Length)
            if ($read -gt 0) {
                if ($Partial) {
                    $res.Text = [System.Text.Encoding]::Default.GetString($buf, 0, $read)
                    $res.Offset = $Offset + $read
                } else {
                    $lastNl = -1
                    for ($k = $read - 1; $k -ge 0; $k--) { if ($buf[$k] -eq 10) { $lastNl = $k; break } }
                    if ($lastNl -ge 0) {
                        $res.Text = [System.Text.Encoding]::Default.GetString($buf, 0, $lastNl + 1)
                        $res.Offset = $Offset + $lastNl + 1
                    }
                }
            }
        }
    } finally {
        if ($fs) { $fs.Close() }
    }
    return $res
}

$ewpDisplay = $Ewp
try { $ewpDisplay = (Resolve-Path -LiteralPath $Ewp).Path } catch { }
Write-Host ("[编译] 工程: {0}" -f $ewpDisplay)
Write-Host ("[编译] 配置: {0}   编译单元: {1}" -f $Config, $(if ($Total -gt 0) { "$Total 个" } else { "未知" }))
Write-Host ("[编译] 日志: {0}" -f $LogFile)
Write-Host ('[编译] 命令: "{0}" "{1}" -build {2} -log all' -f $IarBuild, $Ewp, $Config)

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$proc = Start-Process -FilePath $IarBuild -ArgumentList ('"{0}" -build {1} -log all' -f $Ewp, $Config) -NoNewWindow -PassThru -RedirectStandardOutput $LogFile -RedirectStandardError $errFile

$offset = [long]0
$done = 0
$cur = ''
$cmdPattern = '(?m)^(?:\S*[\\/])?(?:iccarm|iasmarm)\.exe\s'
$namePattern = '(?m)^([A-Za-z0-9_.\-]+\.(?:c|C|cpp|s|S|asm))\s*$'
$cr = [string][char]13

while (-not $proc.HasExited) {
    Start-Sleep -Milliseconds 250
    $chunk = Read-LogChunk -Path $LogFile -Offset $offset
    if ($chunk.Text) {
        $offset = $chunk.Offset
        $n = ([regex]::Matches($chunk.Text, $cmdPattern)).Count
        if ($n -gt 0) { $done += $n }
        $nm = [regex]::Matches($chunk.Text, $namePattern)
        if ($nm.Count -gt 0) { $cur = $nm[$nm.Count - 1].Groups[1].Value }
    }
    $sec = $sw.Elapsed.TotalSeconds
    $label = $(if ($cur) { $cur } else { '等待编译器启动...' })
    if ($label.Length -gt 26) { $label = '..' + $label.Substring($label.Length - 24) }
    if ($Total -gt 0) {
        $pct = [int]([math]::Min(100, ($done * 100 / $Total)))
        $line = "[编译] {0,3}/{1} ({2,3}%)  编译中 {3}{4:N1}s" -f $done, $Total, $pct, (Pad-Visual $label 28), $sec
    } else {
        $line = "[编译] 已编译 {0,3} 个  编译中 {1}{2:N1}s" -f $done, (Pad-Visual $label 28), $sec
    }
    Write-Host ($cr + (Pad-Visual $line 76)) -NoNewline
}

$proc.WaitForExit()
$sw.Stop()

# 收尾：最后一段可能没有换行，也读完
$chunk = Read-LogChunk -Path $LogFile -Offset $offset -Partial
if ($chunk.Text) {
    $offset = $chunk.Offset
    $n = ([regex]::Matches($chunk.Text, $cmdPattern)).Count
    if ($n -gt 0) { $done += $n }
    $nm = [regex]::Matches($chunk.Text, $namePattern)
    if ($nm.Count -gt 0) { $cur = $nm[$nm.Count - 1].Groups[1].Value }
}
Write-Host ""

# stderr 并入日志，等价于原来的 2>&1
if ((Test-Path -LiteralPath $errFile) -and ((Get-Item -LiteralPath $errFile).Length -gt 0)) {
    [System.IO.File]::AppendAllText($LogFile, ([System.IO.File]::ReadAllText($errFile)), [System.Text.Encoding]::Default)
    Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue
}

$errors = 0
$warnings = 0
if (Test-Path -LiteralPath $LogFile) {
    $all = [System.IO.File]::ReadAllText($LogFile, [System.Text.Encoding]::Default)
    if ($all -match 'Total number of errors:\s+(\d+)')   { $errors   = [int]$Matches[1] }
    if ($all -match 'Total number of warnings:\s+(\d+)') { $warnings = [int]$Matches[1] }
    if ($errors -gt 0) {
        $bad = Select-String -LiteralPath $LogFile -Pattern 'Error\[\w+\]|Fatal error' | Select-Object -First 8
        foreach ($b in $bad) { Write-Host ("  " + $b.Line.Trim()) }
    }
}

if ($Total -gt 0) {
    Write-Host ("[编译完成] {0}/{1} 个编译单元，用时 {2:N1}s，错误 {3}，警告 {4}" -f $done, $Total, $sw.Elapsed.TotalSeconds, $errors, $warnings)
} else {
    Write-Host ("[编译完成] 共 {0} 个编译单元，用时 {1:N1}s，错误 {2}，警告 {3}" -f $done, $sw.Elapsed.TotalSeconds, $errors, $warnings)
}

$code = 0
try {
    $proc.Refresh()
    if ($null -ne $proc.ExitCode) { $code = $proc.ExitCode }
    elseif ($errors -gt 0)        { $code = 1 }
} catch {
    if ($errors -gt 0) { $code = 1 }
}
exit $code
