<#
.SYNOPSIS
    识别 IAR 安装与 .ewp 工程，自动选择生成 compile_commands.json 的方式。

.DESCRIPTION
    高版本 IAR（iarbuild 自带 -compdb 或 -jsondb）：直接由 IAR 生成，不必编译。
    低版本 IAR（只有 -build/-make，如 7.5）：先编译并用 -log all 记录命令行，
    再由 gen_compile_commands.ps1 解析日志生成数据库。
    能力用“跑一次 iarbuild 看用法文本”的方式探测，不按版本号硬编码。

.PARAMETER IarRoot
    IAR 安装目录，可指向安装根、common\bin 或 IarBuild.exe；省略则自动扫描，
    扫到多个时列出编号让用户选。

.PARAMETER Ewp
    .ewp 工程文件；省略则在工作区根目录（含 Project\）自动查找，多个时给出编号选择。

.PARAMETER Config
    构建配置名，默认 Debug。

.PARAMETER OutFile
    输出路径，默认 <工作区根>\compile_commands.json。

.PARAMETER LogFile
    低版本模式下的构建日志，默认 %TEMP%\iar75_build.log。

.PARAMETER Mode
    auto（默认）/ compdb / jsondb / log。

.PARAMETER Manual
    关闭一切自动识别：必须同时给出 -Ewp 与 -IarRoot，找不到就直接报错。
    老工程必须用老版本 IAR 编译时（不想被自动挑到新版）用这个开关。

.PARAMETER List
    只列出识别到的 IAR 与工程，不做任何构建。

.PARAMETER DryRun
    只打印将要执行的命令，不实际运行。

.PARAMETER NoPause
    由 build_compile_commands.bat 使用：结束后不再等待回车。脚本本身忽略此参数。
#>
[CmdletBinding()]
param(
    [string]$IarRoot,
    [string]$Ewp,
    [string]$Config = 'Debug',
    [string]$OutFile,
    [string]$LogFile,
    [ValidateSet('auto', 'compdb', 'jsondb', 'log')][string]$Mode = 'auto',
    [Alias('NoAuto')][switch]$Manual,
    [switch]$List,
    [switch]$DryRun,
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'

# 兜底：任何未预料的异常也只打一行，不甩堆栈
trap {
    Write-Host ''
    Write-Host ('[ERROR] ' + $_.Exception.Message)
    exit 1
}

. (Join-Path $PSScriptRoot 'iar_env.ps1')

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if (-not $OutFile) { $OutFile = Join-Path $Root 'compile_commands.json' }
if (-not $LogFile) { $LogFile = Join-Path $env:TEMP 'iar75_build.log' }

function Fail {
    param([string]$Text, [int]$Code = 1)
    Write-Host ''
    Write-Host ('[ERROR] ' + $Text)
    exit $Code
}

# 打印实际执行的命令，前缀 > 便于和结果区分
function Write-Cmd {
    param([string]$Text)
    Write-Host ('  > ' + $Text)
}

function Get-CompDbCount {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return -1 }
    try {
        $db = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        return @($db).Count
    } catch {
        return -1
    }
}

# 按候选字段名取第一个非空值（不同 IAR 版本的 jsondb 字段名不完全一致）
function Get-EntryValue {
    param($Item, [string[]]$Names)
    foreach ($n in $Names) {
        $v = $Item.$n
        # 逗号包一层：powershell 返回数组时会被展开，单元素数组会退化成字符串
        if ($null -ne $v -and "$v" -ne '') { return ,$v }
    }
    return $null
}

# -jsondb 的结果里混有链接/转换步骤，且各版本字段名有差异，这里宽松解析：
#   工具名 type/tool/compiler，目录 directory/dir/cwd，输入 file/files/inputs，
#   参数 arguments/args 数组或一整条 command 字符串。只保留“编译源文件”的条目。
function Convert-JsonDbToCompDb {
    param([string]$InFile, [string]$OutFile, [string]$IccArm, [string]$IasmArm)

    $raw = Get-Content -LiteralPath $InFile -Raw | ConvertFrom-Json

    # 顶层可能直接是数组，也可能把数组包在某个属性里
    $items = @()
    if ($raw -is [array]) {
        $items = @($raw)
    } else {
        $arrProp = $raw.PSObject.Properties | Where-Object { $_.Value -is [array] } | Select-Object -First 1
        if ($arrProp) { $items = @($arrProp.Value) } else { $items = @($raw) }
    }

    $entries = New-Object System.Collections.Generic.List[object]
    $skipped = 0

    foreach ($it in $items) {
        $tool = [string](Get-EntryValue $it @('type', 'tool', 'compiler', 'name'))
        $dir  = [string](Get-EntryValue $it @('directory', 'dir', 'cwd', 'workingDirectory'))

        $files = @()
        $one = Get-EntryValue $it @('file', 'input', 'source')
        if ($one) { $files += [string]$one }
        foreach ($n in @('files', 'inputs', 'sources')) {
            $many = $it.$n
            if ($many) { foreach ($f in @($many)) { $files += [string]$f } }
        }

        # 没有 .c/.cpp/.s 输入的就是链接/转换步骤，跳过
        $srcFiles = @($files | Where-Object { $_ -match '(?i)\.(c|cpp|cc|cxx|s|asm)$' })
        if ($srcFiles.Count -eq 0) { $skipped++; continue }

        $argv = $null
        $cmd = [string](Get-EntryValue $it @('command', 'commandLine', 'cmd'))

        $rawArgs = Get-EntryValue $it @('arguments', 'args', 'argv')
        if ($rawArgs -is [string]) {
            # 有的版本把整条命令行塞进 arguments 字符串，此时按 command 处理
            if (-not $cmd) { $cmd = [string]$rawArgs }
        } elseif ($rawArgs) {
            $argv = @()
            foreach ($a in @($rawArgs)) { $argv += [string]$a }
        }

        if (-not $argv -and -not $cmd) { $skipped++; continue }

        if ($argv) {
            $exe = $IccArm
            if ($tool -match '(?i)iasmarm' -or $cmd -match '(?i)iasmarm') { $exe = $IasmArm }
            if ($argv[0] -notmatch '(?i)\.exe$' -and $exe) { $argv = @($exe) + $argv }
        }

        foreach ($f in $srcFiles) {
            if ($argv) {
                $entries.Add([pscustomobject]@{ directory = $dir; file = $f; arguments = $argv })
            } else {
                $entries.Add([pscustomobject]@{ directory = $dir; file = $f; command = $cmd })
            }
        }
    }

    if ($entries.Count -eq 0) {
        Write-Host ("[WARN] 没能从 json 里识别出编译条目（原始 {0} 条，跳过 {1} 条）" -f $items.Count, $skipped)
        try {
            Write-Host ("       文件: {0}  ({1:N0} 字节)" -f $InFile, (Get-Item -LiteralPath $InFile).Length)
            if ($items.Count -gt 0) {
                $keys = (($items[0].PSObject.Properties | ForEach-Object { $_.Name }) -join ', ')
                Write-Host ("       首条字段: {0}" -f $keys)
                $preview = ($items[0] | ConvertTo-Json -Depth 3 -Compress)
                if ($preview.Length -gt 400) { $preview = $preview.Substring(0, 400) + ' ...' }
                Write-Host ("       首条内容: {0}" -f $preview)
            } else {
                $keys = (($raw.PSObject.Properties | ForEach-Object { $_.Name }) -join ', ')
                Write-Host ("       顶层字段: {0}" -f $keys)
            }
        } catch { }
    } elseif ($skipped -gt 0) {
        Write-Host ("  （另有 {0} 条链接/转换步骤已忽略）" -f $skipped)
    }

    $json = $entries | ConvertTo-Json -Depth 10
    if ($entries.Count -eq 0) { $json = '[]' }
    if ($entries.Count -eq 1) { $json = '[' + $json + ']' }
    [System.IO.File]::WriteAllText($OutFile, $json, (New-Object System.Text.UTF8Encoding($false)))
    return $entries.Count
}

# 运行外部程序并原地刷新一行耗时，避免大工程时看着像卡死
function Invoke-WithSpinner {
    param([string]$Exe, [string]$ArgLine, [string]$Label, [string]$OutLog, [string]$ErrLog)

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $p = Start-Process -FilePath $Exe -ArgumentList $ArgLine -NoNewWindow -PassThru -RedirectStandardOutput $OutLog -RedirectStandardError $ErrLog
    $cr = [string][char]13
    while (-not $p.HasExited) {
        Start-Sleep -Milliseconds 200
        $line = "[{0}] 运行中 {1,6:N1}s" -f $Label, $sw.Elapsed.TotalSeconds
        Write-Host ($cr + $line.PadRight(40)) -NoNewline
    }
    $p.WaitForExit()
    $sw.Stop()
    Write-Host ""
    $p.Refresh()
    $code = 0
    if ($null -ne $p.ExitCode) { $code = $p.ExitCode }
    return $code
}

# 列出编号让人选；输入为空/无法读取则返回 0（等于取消）
function Read-Choice {
    param([string]$Title, [string[]]$Lines, [string]$Hint)

    Write-Host $Title
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        Write-Host ("  [{0}] {1}" -f ($i + 1), $Lines[$i])
    }
    Write-Host ''
    Write-Host $Hint

    while ($true) {
        $ans = $null
        try { $ans = Read-Host ('编号 [1-' + $Lines.Count + ']') } catch { return 0 }
        if (-not $ans) { return 0 }

        $n = 0
        if ([int]::TryParse($ans.Trim(), [ref]$n) -and $n -ge 1 -and $n -le $Lines.Count) {
            return $n
        }
        Write-Host '  请输入列表中的编号。'
    }
}

$installs = @()
if ($List -or (-not $IarRoot -and -not $Manual)) { $installs = @(Get-IarInstallations -Probe) }

$savedVersion = ''

if ($List) {
    Write-Host '=== IAR 安装 ==='
    if ($installs.Count -eq 0) {
        Write-Host '  （未在 Program Files 下找到，可用 -IarRoot 指定）'
    } else {
        foreach ($i in $installs) {
            Write-Host ("  {0,-6} {1,-18} {2}" -f $i.Version, (Get-IarCapabilityText $i), $i.Root)
        }
    }
    Write-Host ''
    Write-Host '=== 工程 (.ewp) ==='
    $projs = @(Find-EwpProjects -Root $Root)
    if ($projs.Count -eq 0) {
        Write-Host '  （未找到，可用 -Ewp 指定）'
    } else {
        foreach ($p in $projs) {
            $v = Get-EwpSavedVersion -Ewp $p.FullName
            $vt = '未知'
            if ($v) { $vt = $v }
            Write-Host ("  {0}   (保存版本 {1})" -f $p.FullName, $vt)
        }
    }
    exit 0
}

# ---------- 定位工程 ----------
if ($Ewp) {
    if (-not (Test-Path -LiteralPath $Ewp)) { Fail "找不到工程文件: $Ewp" }
    $EwpPath = (Resolve-Path -LiteralPath $Ewp).Path
} else {
    if ($Manual) { Fail '-Manual 已关闭自动识别，请用 -Ewp 指定工程（可先用 -List 查看有哪些）' }

    $projs = @(Find-EwpProjects -Root $Root)
    if ($projs.Count -eq 0) { Fail '工作区里没找到 .ewp，请用 -Ewp 指定（可先运行 -List 查看）' }

    if ($projs.Count -gt 1) {
        $lines = @()
        foreach ($x in $projs) { $lines += $x.FullName }
        $idx = Read-Choice -Title '找到多个 .ewp 工程：' -Lines $lines -Hint '输入编号选择；直接回车取消（也可以用 -Ewp 指定）。'
        if ($idx -eq 0) { Fail '未选择工程，已取消（可用 -Ewp 指定，或加 -Manual 完全手动）' }
        $EwpPath = $projs[$idx - 1].FullName
    } else {
        $EwpPath = $projs[0].FullName
    }
}
$ProjectDir = Split-Path -Parent $EwpPath
$savedVersion = Get-EwpSavedVersion -Ewp $EwpPath

# ---------- 定位 IAR ----------
if ($IarRoot) {
    $iar = Resolve-IarRoot -Path $IarRoot
    if (-not $iar) { Fail "在 $IarRoot 下没找到 common\bin\IarBuild.exe" }
    $cap = Get-IarCapabilities -IarBuild $iar.IarBuild
    $iar.CompDb = $cap.CompDb
    $iar.JsonDb = $cap.JsonDb
} else {
    if ($Manual) { Fail '-Manual 已关闭自动识别，请用 -IarRoot 指定 IAR 安装目录（可先用 -List 查看）' }
    if ($installs.Count -eq 0) { Fail '没找到已安装的 IAR，请用 -IarRoot 指定（可先运行 -List）' }

    if ($installs.Count -eq 1) {
        $iar = $installs[0]
    } else {
        $rec = Select-IarInstall -Installs $installs -SavedVersion $savedVersion
        $lines = @()
        foreach ($x in $installs) {
            $tag = ''
            if ($rec -and $x.Root -eq $rec.Root) { $tag = '   <- 推荐' }
            $lines += ("{0,-6} {1,-18} {2}{3}" -f $x.Version, (Get-IarCapabilityText $x), $x.Root, $tag)
        }
        $hint = '输入编号选择；直接回车取消（也可以用 -IarRoot 指定）。'
        if ($savedVersion) { $hint = "工程由 $savedVersion 保存。$hint" }
        $idx = Read-Choice -Title '找到多个 IAR 安装：' -Lines $lines -Hint $hint
        if ($idx -eq 0) { Fail '未选择 IAR，已取消（可用 -IarRoot 指定）' }
        $iar = $installs[$idx - 1]
    }
}

# ---------- 打印识别结果 ----------
Write-Host '=== 环境识别 ==='
Write-Host ("  IAR   : {0}  {1}" -f $iar.Version, $iar.Root)
Write-Host ("  能力  : {0}" -f (Get-IarCapabilityText $iar))
if ($savedVersion) { Write-Host ("  工程自 : {0} 保存" -f $savedVersion) }
Write-Host ("  工程  : {0}  [{1}]" -f $EwpPath, $Config)
Write-Host ("  产物  : {0}" -f $OutFile)

# ---------- 选择方式 ----------
$useMode = $Mode
if ($useMode -eq 'auto') {
    if ($iar.CompDb) { $useMode = 'compdb' }
    elseif ($iar.JsonDb) { $useMode = 'jsondb' }
    else { $useMode = 'log' }
}
if ($useMode -eq 'compdb' -and -not $iar.CompDb) {
    Write-Host '[WARN] 该 IAR 的用法里没列出 -compdb，仍按你的要求尝试；失败会打印 IAR 自己的输出'
}
if ($useMode -eq 'jsondb' -and -not $iar.JsonDb) {
    Write-Host '[WARN] 该 IAR 的用法里没列出 -jsondb，仍按你的要求尝试；失败会打印 IAR 自己的输出'
}

$modeText = '编译日志解析（该版本无内置能力）'
if ($useMode -eq 'compdb') { $modeText = 'iarbuild -compdb 直接生成（IAR 内置）' }
if ($useMode -eq 'jsondb') { $modeText = 'iarbuild -jsondb 生成后转换' }
Write-Host ("  方式  : {0}" -f $modeText)
Write-Host ''

# 低版本流程：全量编译（带进度）→ 解析日志
function Invoke-LogMode {
    Write-Host ("=== [1/2] 编译（IAR {0}, {1}）===" -f $iar.Version, $Config)
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'run_iar_build.ps1') -IarBuild $iar.IarBuild -Ewp $EwpPath -Config $Config -LogFile $LogFile
    $buildRc = $LASTEXITCODE

    Write-Host ''
    Write-Host '=== [2/2] 解析日志生成 compile_commands.json ==='
    $genScript = Join-Path $PSScriptRoot 'gen_compile_commands.ps1'
    Write-Cmd ('powershell -NoProfile -ExecutionPolicy Bypass -File "{0}" -LogFile "{1}" -OutFile "{2}" -ProjectDir "{3}" -IarRoot "{4}"' -f $genScript, $LogFile, $OutFile, $ProjectDir, $iar.Root)
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $genScript -LogFile $LogFile -OutFile $OutFile -ProjectDir $ProjectDir -IarRoot $iar.Root
    $genRc = $LASTEXITCODE

    if ($buildRc -ne 0) { Write-Host ("[WARN] 编译有错误（退出码 {0}），请查看日志: {1}" -f $buildRc, $LogFile) }
    if ($genRc -ne 0) { Fail "生成 compile_commands.json 失败（退出码 $genRc）" }
}

$jsonTmp = Join-Path $env:TEMP 'iar_project_jsondb.json'

# 只打印命令不执行，方便确认到底调用了什么
if ($DryRun) {
    Write-Host '将要执行的命令：'
    if ($useMode -eq 'compdb') {
        Write-Host ('  "{0}" "{1}" -compdb {2} -output "{3}"' -f $iar.IarBuild, $EwpPath, $Config, $OutFile)
        Write-Host '  （IAR 直接写出 compile_commands.json，脚本不做转换）'
    } elseif ($useMode -eq 'jsondb') {
        Write-Host ('  "{0}" "{1}" -jsondb {2} -output "{3}"' -f $iar.IarBuild, $EwpPath, $Config, $jsonTmp)
        Write-Host ('  再把 json 转成: {0}' -f $OutFile)
    } else {
        Write-Host ('  "{0}" "{1}" -build {2} -log all' -f $iar.IarBuild, $EwpPath, $Config)
        Write-Host ('  再解析日志: {0} -> {1}' -f $LogFile, $OutFile)
    }
    exit 0
}

$tmpOut = Join-Path $env:TEMP 'iar_compdb_out.log'
$tmpErr = Join-Path $env:TEMP 'iar_compdb_err.log'

# 个别版本会忽略 -output，仍然写到工程目录，这里做一次兜底搬运
function Get-FallbackOutput {
    param([string]$Dir, [string]$Name)
    $p = Join-Path $Dir $Name
    if (Test-Path -LiteralPath $p) { return $p }
    return $null
}

# 有些 9.x 的用法文本里没有 -compdb，但实际支持；auto 模式下先悄悄试一次，
# 成功就直接用 IAR 的产物（零转换），失败就静默回退到 -jsondb。
if ($useMode -eq 'jsondb' -and $Mode -eq 'auto' -and -not $iar.CompDb) {
    $probeFile = Join-Path $env:TEMP 'iar_compdb_probe.json'
    Remove-Item -LiteralPath $probeFile -Force -ErrorAction SilentlyContinue
    $probeArgs = '"{0}" -compdb {1} -output "{2}"' -f $EwpPath, $Config, $probeFile
    $probeProc = Start-Process -FilePath $iar.IarBuild -ArgumentList $probeArgs -NoNewWindow -Wait -PassThru -RedirectStandardOutput $tmpOut -RedirectStandardError $tmpErr
    $probeRc = 0
    if ($null -ne $probeProc.ExitCode) { $probeRc = $probeProc.ExitCode }

    $probeOk = $false
    if ($probeRc -eq 0 -and (Test-Path -LiteralPath $probeFile)) {
        try {
            $probeDb = Get-Content -LiteralPath $probeFile -Raw | ConvertFrom-Json
            if (@($probeDb).Count -gt 0) { $probeOk = $true }
        } catch { $probeOk = $false }
    }

    if ($probeOk) {
        Move-Item -LiteralPath $probeFile -Destination $OutFile -Force
        Write-Host '  （该版本实际支持 -compdb，已由 IAR 直接生成，无转换）'
        $count = Get-CompDbCount -Path $OutFile
        Write-Host ''
        Write-Host ("[完成] {0} 条编译命令 -> {1}" -f $count, $OutFile)
        exit 0
    }

    Remove-Item -LiteralPath $probeFile -Force -ErrorAction SilentlyContinue
}

if ($useMode -eq 'compdb') {

    Write-Host ("=== [1/1] iarbuild -compdb {0} ===" -f $Config)
    $argLine = '"{0}" -compdb {1} -output "{2}"' -f $EwpPath, $Config, $OutFile
    Write-Cmd ('"{0}" {1}' -f $iar.IarBuild, $argLine)
    $rc = Invoke-WithSpinner -Exe $iar.IarBuild -ArgLine $argLine -Label 'compdb' -OutLog $tmpOut -ErrLog $tmpErr

    if (-not (Test-Path -LiteralPath $OutFile)) {
        $fb = Get-FallbackOutput -Dir $ProjectDir -Name 'compile_commands.json'
        if ($fb) { Move-Item -LiteralPath $fb -Destination $OutFile -Force }
    }

    if ($rc -ne 0 -or -not (Test-Path -LiteralPath $OutFile)) {
        if (Test-Path -LiteralPath $tmpOut) {
            Get-Content -LiteralPath $tmpOut | Select-Object -Last 10 | ForEach-Object { Write-Host ('  ' + $_) }
        }
        Fail "iarbuild -compdb 失败（退出码 $rc）"
    }

} elseif ($useMode -eq 'jsondb') {

    Write-Host ("=== [1/2] iarbuild -jsondb {0} ===" -f $Config)
    Remove-Item -LiteralPath $jsonTmp -Force -ErrorAction SilentlyContinue

    $argLine = '"{0}" -jsondb {1} -output "{2}"' -f $EwpPath, $Config, $jsonTmp
    Write-Cmd ('"{0}" {1}' -f $iar.IarBuild, $argLine)
    $rc = Invoke-WithSpinner -Exe $iar.IarBuild -ArgLine $argLine -Label 'jsondb' -OutLog $tmpOut -ErrLog $tmpErr

    if (-not (Test-Path -LiteralPath $jsonTmp)) {
        $fb = Get-ChildItem -LiteralPath $ProjectDir -Filter '*_jsondb.json' -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($fb) { Copy-Item -LiteralPath $fb.FullName -Destination $jsonTmp -Force }
    }

    if ($rc -ne 0 -or -not (Test-Path -LiteralPath $jsonTmp)) {
        if (Test-Path -LiteralPath $tmpOut) {
            Get-Content -LiteralPath $tmpOut | Select-Object -Last 10 | ForEach-Object { Write-Host ('  ' + $_) }
        }
        Fail "iarbuild -jsondb 失败（退出码 $rc）"
    }

    Write-Host '=== [2/2] 转换为 compile_commands.json ==='
    Write-Host '  说明  : -jsondb 的产物还含链接/自定义步骤，字段也与 CDB 不完全一致，需过滤后写出'
    Write-Cmd ('脚本内置转换: {0} -> {1}' -f $jsonTmp, $OutFile)
    $n = Convert-JsonDbToCompDb -InFile $jsonTmp -OutFile $OutFile -IccArm $iar.IccArm -IasmArm $iar.IasmArm
    Write-Host ("  已转换 {0} 条" -f $n)

    # 和工程里的源文件数对一下，数量对不上就提醒（不一定错，但值得看一眼）
    $expected = 0
    try {
        [xml]$ewpXml = Get-Content -LiteralPath $EwpPath -Raw
        $expected = @($ewpXml.SelectNodes('//file') | Where-Object { $_.InnerText -match '\.(c|cpp|cc|s|asm)$' }).Count
    } catch { }
    if ($n -gt 0 -and $expected -gt 0 -and $n -lt $expected) {
        Write-Host ("[WARN] 只提取到 {0} 条，工程里有 {1} 个源文件，结果可能不完整（可加 -Mode log 对照）" -f $n, $expected)
    }

    if ($n -eq 0) {
        if ($Mode -eq 'jsondb') {
            Fail "没能从 -jsondb 结果里提取出编译条目，原文件保留在: $jsonTmp"
        }
        Write-Host ''
        Write-Host '[WARN] -jsondb 结果里没有可用的编译条目，改用日志解析（需要全量编译一次）'
        Write-Host ''
        Invoke-LogMode
    }

} else {

    Invoke-LogMode
}

$count = Get-CompDbCount -Path $OutFile
if ($count -lt 0) { Fail "输出不是有效的 JSON: $OutFile" }
Write-Host ''
Write-Host ("[完成] {0} 条编译命令 -> {1}" -f $count, $OutFile)
exit 0
