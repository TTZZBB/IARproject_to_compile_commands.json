<#
.SYNOPSIS
    由 IAR 7.5 的构建日志生成 clangd 可用的 compile_commands.json。

.DESCRIPTION
    IAR 7.5 的 iarbuild 不支持 -jsondb，无法原生导出编译数据库；
    而 `iarbuild <project> -build <config> -log all` 会为每个源文件打印
    实际执行的完整命令行。本脚本只做“格式转换”，把日志中的命令行
    解析成标准 JSON Compilation Database（每条命令的参数均来自
    IAR 7.5 真实执行的原始命令行，不做任何手工编造）。

.PARAMETER LogFile
    `iarbuild ... -log all` 的输出日志，默认 %TEMP%\iar75_build.log。

.PARAMETER OutFile
    输出的 compile_commands.json，默认写到工作区根目录。

.PARAMETER ProjectDir
    编译时的工作目录（.ewp 所在目录），写入条目的 directory 字段。

.PARAMETER IarRoot
    IAR Embedded Workbench 安装根目录，用于补全 iccarm/iasmarm 绝对路径。
#>
[CmdletBinding()]
param(
    [string]$LogFile,
    [string]$OutFile,
    [string]$ProjectDir,
    [string]$IarRoot = 'C:\Program Files (x86)\IAR Systems\Embedded Workbench 7.5'
)

$ErrorActionPreference = 'Stop'

# 工作区根目录 = tools\ 的上一级
$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if (-not $LogFile)    { $LogFile    = Join-Path $env:TEMP 'iar75_build.log' }
if (-not $OutFile)    { $OutFile    = Join-Path $Root 'compile_commands.json' }
if (-not $ProjectDir) { $ProjectDir = Join-Path $Root 'Project\GD32F303_Prj' }

if (-not (Test-Path -LiteralPath $LogFile)) {
    throw "找不到构建日志: $LogFile（请先执行 iarbuild ... -build <config> -log all）"
}

$ToolMap = @{
    'iccarm.exe'  = Join-Path $IarRoot 'arm\bin\iccarm.exe'
    'iasmarm.exe' = Join-Path $IarRoot 'arm\bin\iasmarm.exe'
}

$entries = New-Object System.Collections.Generic.List[object]

$lines = Get-Content -LiteralPath $LogFile
Write-Host ("[转换] 日志共 {0} 行，开始解析 ..." -f $lines.Count)
$parsed = 0

foreach ($line in $lines) {
    # 日志中编译器/汇编器行形如: iccarm.exe <源文件> -lCN ... -o ... -I ...
    $m = [regex]::Match($line, '^(?:\S*[\\/])?(iccarm|iasmarm)\.exe\s')
    if (-not $m.Success) { continue }

    $tool = $m.Groups[1].Value + '.exe'
    $tokens = $line.Substring($m.Length).Trim() -split ' +'

    # 以盘符开头的 token 是一条完整路径的起点；路径本身可能含空格
    # （如 C:\Program Files (x86)\...），需把后续 token 拼接回下一个
    # 以 '-' 开头的选项之前，才能还原成单个参数。
    $argv = New-Object System.Collections.Generic.List[string]
    $i = 0
    while ($i -lt $tokens.Count) {
        if ($tokens[$i] -match '^[A-Za-z]:[\\/]') {
            $p = $tokens[$i]; $i++
            while ($i -lt $tokens.Count -and $tokens[$i] -notmatch '^-') {
                $p += ' ' + $tokens[$i]; $i++
            }
            $argv.Add($p)
        } else {
            $argv.Add($tokens[$i]); $i++
        }
    }

    if ($argv.Count -lt 1) { continue }

    $src = $argv[0]
    $argv.Insert(0, $ToolMap[$tool])  # 日志里只有 exe 名，补全为绝对路径

    $entries.Add([pscustomobject]@{
        directory = $ProjectDir
        file      = $src
        arguments = $argv.ToArray()
    })

    $parsed++
    if (($parsed % 10) -eq 0) {
        Write-Host (([string][char]13) + ("[转换] 已解析 {0} 条命令" -f $parsed).PadRight(46)) -NoNewline
    }
}

if ($parsed -gt 0) { Write-Host "" }
if ($entries.Count -eq 0) {
    throw "日志里没有找到 iccarm/iasmarm 命令行，请确认 -LogFile 指向 iarbuild -log all 的输出: $LogFile"
}
Write-Host ("[转换] 写出 {0}" -f $OutFile)
$json = $entries | ConvertTo-Json -Depth 10
if ($entries.Count -eq 1) { $json = '[' + $json + ']' }
[System.IO.File]::WriteAllText(
    $OutFile,
    $json,
    (New-Object System.Text.UTF8Encoding($false))
)
Write-Host ("[转换] 完成: {0:N1} KB" -f ((Get-Item -LiteralPath $OutFile).Length / 1KB))
Write-Host ("compile_commands.json: {0} 条编译命令 -> {1}" -f $entries.Count, $OutFile)
