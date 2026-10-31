# IAR → compile_commands.json 生成工具

## 背景

IAR Embedded Workbench 7.5 的 `iarbuild` 只支持 `-clean / -build / -make / -cstat *`，
没有 `-compdb` / `-jsondb`（这两个能力是 8.x/9.x 之后才有的），因此无法原生导出 clangd
需要的 `compile_commands.json`。

但 `iarbuild <project> -build <config> -log all` 会为**每个源文件打印实际执行的完整命令行**。
本工具把两条路都覆盖：

| IAR 版本 | iarbuild 能力 | 本工具的做法 |
| --- | --- | --- |
| 9.x（较新） | `-compdb` / `-jsondb` | 直接让 IAR 生成 `compile_commands.json`，不编译，几秒完成 |
| 7.5 / 8.3 等 | 只有 `-build` / `-make` | 全量编译 + `-log all`，再把日志解析成数据库 |

具体执行的命令：

```bat
:: 9.x 且用法里有 -compdb：IAR 直接写出 compile_commands.json，脚本不转换
iarbuild "xxx.ewp" -compdb Debug -output "<工作区根>\compile_commands.json"

:: 只公布 -jsondb 的版本：先出项目 json，再由脚本提取编译条目
iarbuild "xxx.ewp" -jsondb Debug -output "%TEMP%\iar_project_jsondb.json"

:: 7.5 / 8.3（没有以上选项）：全量编译并记录命令行，再解析日志
iarbuild "xxx.ewp" -build Debug -log all  >  "%TEMP%\iar75_build.log"
```

想看当前环境会走哪条、具体跑什么命令：`tools\build_compile_commands.bat -DryRun`。

> 9.x 用法里没写 `-compdb` 时，`auto` 会先悄悄试一次：能用就直接由 IAR 输出（**无中间文件、无转换**），
> 不能用再退回 `-jsondb`，并在控制台说明为什么要转换。

能力不是按版本号猜的：脚本会跑一次 `iarbuild` 看用法文本里有没有 `-compdb` / `-jsondb`，
所以不同产品线、不同小版本都能自动选对。

> 备选方案说明：用 IAR 9.1 的 `iarbuild -jsondb` 也能读 7.5 的 `.ewp`，
> 但它生成的命令里编译器是 **9.1 的** `iccarm.exe` 和 9.1 的 DLib 路径。
> 要保证与 7.5 完全一致，就仍走“解析 7.5 自身构建日志”这条路。

## 文件

| 文件 | 说明 |
| --- | --- |
| `build_compile_commands.bat` | 入口：参数原样透传给 PowerShell |
| `build_compile_commands.ps1` | 编排：识别 IAR / 工程 → 选方式 → 生成 |
| `iar_env.ps1` | 识别库：扫描 IAR 安装、探测能力、查找 `.ewp` |
| `run_iar_build.ps1` | 低版本：调用 IarBuild 并实时显示编译进度 |
| `gen_compile_commands.ps1` | 低版本：把构建日志解析成 `compile_commands.json` |
| `../compile_commands.json` | 生成产物，位于工作区根目录 |

## 用法

### 一键（推荐）

双击 `build_compile_commands.bat`，或在命令行执行：

```bat
tools\build_compile_commands.bat
```

它会依次：扫描 IAR → 找 `.ewp` → 按能力选方式 → 生成，并把识别结果先打印出来。

运行结束后会停在 `按回车键退出 ...`，按回车才关闭窗口——双击运行时也能看完整个输出。
脚本 / CI 里调用请加 `-NoPause`（或设环境变量 `NO_PAUSE=1`）直接退出。

工作区里有多个 `.ewp` 时不会瞎猜，会列出来让你选（直接回车 = 取消）：

```text
找到多个 .ewp 工程：
  [1] D:\work\...\Project\GD32F303_Prj\Car_MCU.ewp
  [2] D:\work\...\Project\GD32F303_Prj\Car_MCU_Boot.ewp

输入编号选择；直接回车取消（也可以用 -Ewp 指定）。
```

装了多个 IAR 时同样会让你选，并把与工程保存版本一致的那个标成推荐：

```text
找到多个 IAR 安装：
  [1] 7.5    -jsondb            C:\Program Files (x86)\IAR Systems\Embedded Workbench 7.5   <- 推荐
  [2] 9.1    -compdb / -jsondb  C:\Program Files\IAR Systems\Embedded Workbench 9.1
工程由 7.50.2.0 保存。输入编号选择；直接回车取消（也可以用 -IarRoot 指定）。
```

### 先看看识别到什么

```bat
tools\build_compile_commands.bat -List
```

```text
=== IAR 安装 ===
  7.5    无（走日志解析）      C:\Program Files (x86)\IAR Systems\Embedded Workbench 7.5
  9.1    -compdb / -jsondb    C:\Program Files\IAR Systems\Embedded Workbench 9.1

=== 工程 (.ewp) ===
  D:\work\Car_MCU\Project\GD32F303_Prj\Car_MCU.ewp   (保存版本 7.50.2.0)
```

### 完全手动（关闭自动识别）

老工程必须用老版本 IAR 编译、不想让脚本自己挑的时候：

```bat
tools\build_compile_commands.bat -Manual ^
  -Ewp "Project\GD32F303_Prj\Car_MCU.ewp" ^
  -IarRoot "C:\Program Files (x86)\IAR Systems\Embedded Workbench 7.5"
```

`-Manual`（别名 `-NoAuto`）下这两个参数都必须给，缺一个立刻报错，不做任何扫描；
这样就不会出现“拿 9.x 去编 7.5 的老工程”。需要的话再叠加 `-Mode log` 强制走日志解析。

### 指定 IAR / 工程

```bat
:: 指定 IAR 安装目录（安装根、common\bin、IarBuild.exe 三种都认）
tools\build_compile_commands.bat -IarRoot "C:\Program Files (x86)\IAR Systems\Embedded Workbench 7.5"

:: 指定工程与配置
tools\build_compile_commands.bat -Ewp "D:\work\Car_MCU\Project\Car_MCU.ewp" -Config Debug

:: 指定产物路径
tools\build_compile_commands.bat -OutFile "D:\work\compile_commands.json"
```

什么都不指定时的挑选规则：

1. IAR：读 `.ewp` 里的保存版本（`OGLastSavedByProductVersion`），优先选同版本；没有同版本就用已装的最新版。
2. 工程：先找 `<工作区根>\Project\**\*.ewp`，找不到再在根目录浅层搜索；多于一个会列出来让你用 `-Ewp` 指定。

### 强制某种方式

```bat
tools\build_compile_commands.bat -Mode compdb   :: 必须支持 -compdb，否则明确报错
tools\build_compile_commands.bat -Mode jsondb
tools\build_compile_commands.bat -Mode log      :: 强制走“编译 + 解析日志”
```

### 分步 / 自定义

```bat
:: 低版本：先编译（带进度），日志写到 %TEMP%\iar75_build.log
powershell -NoProfile -ExecutionPolicy Bypass -File tools\run_iar_build.ps1 ^
  -IarBuild "C:\Program Files (x86)\IAR Systems\Embedded Workbench 7.5\common\bin\IarBuild.exe" ^
  -Ewp Project\GD32F303_Prj\Car_MCU.ewp -Config Debug

:: 再从日志生成数据库
powershell -NoProfile -ExecutionPolicy Bypass -File tools\gen_compile_commands.ps1 -IarRoot "C:\Program Files (x86)\IAR Systems\Embedded Workbench 7.5"
```

> 低版本只想增量编译时可以把 `-build` 换成 `-make`，但日志里会缺少未变更文件的命令行，
> 生成的数据库不完整——这一点和以前一样。

## 运行输出

低版本（编译 + 解析）：

```text
=== 环境识别 ===
  IAR   : 8.3  C:\Program Files (x86)\IAR Systems\Embedded Workbench 8.3
  能力  : 无（走日志解析）
  工程自 : 7.50.2.0 保存
  工程  : D:\work\Car_MCU\Project\GD32F303_Prj\Car_MCU.ewp  [Debug]
  产物  : D:\work\Car_MCU\compile_commands.json
  方式  : 编译日志解析（该版本无内置能力）

=== [1/2] 编译（IAR 8.3, Debug）===
[编译] 命令: "…\IarBuild.exe" "…\Car_MCU.ewp" -build Debug -log all
[编译]  31/52 ( 60%)  编译中 bsp_timer.c                 12.4s
[编译完成] 52/52 个编译单元，用时 20.7s，错误 0，警告 0

=== [2/2] 解析日志生成 compile_commands.json ===
  > powershell -NoProfile -ExecutionPolicy Bypass -File "…\gen_compile_commands.ps1" -LogFile "…\iar75_build.log" -OutFile "…\compile_commands.json" -ProjectDir "…" -IarRoot "…"
[转换] 日志共 647 行，开始解析 ...
[转换] 已解析 50 条命令
[转换] 写出 D:\work\Car_MCU\compile_commands.json
compile_commands.json: 52 条编译命令 -> D:\work\Car_MCU\compile_commands.json

[完成] 52 条编译命令 -> D:\work\Car_MCU\compile_commands.json
```

以 `>` 开头的行是脚本实际执行的命令，方便核对参数。

高版本（IAR 直接生成，不编译）：

```text
=== 环境识别 ===
  IAR   : 9.1  C:\Program Files\IAR Systems\Embedded Workbench 9.1
  能力  : -compdb / -jsondb
  方式  : iarbuild -compdb 直接生成（IAR 内置）

=== [1/1] iarbuild -compdb Debug ===
  > "…\IarBuild.exe" "…\Car_MCU.ewp" -compdb Debug -output "…\compile_commands.json"
[compdb] 运行中    1.3s

[完成] 52 条编译命令 -> D:\work\Car_MCU\compile_commands.json
```

## 参数

### build_compile_commands.ps1

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `-IarRoot` | 自动扫描（多个时列出选择） | IAR 安装目录（根 / `common\bin` / `IarBuild.exe` 均可） |
| `-Ewp` | 自动查找 | `.ewp` 工程文件 |
| `-Config` | `Debug` | 构建配置名 |
| `-OutFile` | `<工作区根>\compile_commands.json` | 输出路径 |
| `-LogFile` | `%TEMP%\iar75_build.log` | 低版本模式的构建日志 |
| `-Mode` | `auto` | `auto` / `compdb` / `jsondb` / `log` |
| `-List` | - | 只列出识别结果，不做构建 |
| `-Manual` | - | 关闭自动识别，必须同时给 `-Ewp` 与 `-IarRoot`（别名 `-NoAuto`） |
| `-DryRun` | - | 只打印将要执行的命令，不实际运行 |
| `-NoPause` | - | 结束后不等待回车（批处理传参用） |

### gen_compile_commands.ps1

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `-LogFile` | `%TEMP%\iar75_build.log` | `iarbuild ... -log all` 的输出日志 |
| `-OutFile` | `<工作区根>\compile_commands.json` | 输出路径 |
| `-ProjectDir` | `<工作区根>\Project\GD32F303_Prj` | 写入条目的 `directory` 字段（.ewp 所在目录） |
| `-IarRoot` | `...\Embedded Workbench 7.5` | 用于把日志中的 `iccarm.exe` / `iasmarm.exe` 补全为绝对路径 |

### run_iar_build.ps1

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `-IarBuild` | 必填 | `IarBuild.exe` 绝对路径 |
| `-Ewp` | 必填 | `.ewp` 工程文件 |
| `-Config` | `Debug` | 构建配置名 |
| `-LogFile` | `%TEMP%\iar75_build.log` | 构建日志输出路径（供转换脚本解析） |
| `-Total` | 从 `.ewp` 统计 | 编译单元总数，仅用于进度显示 |

## 环境要求

- IAR Embedded Workbench for ARM（7.5 可用；9.x 走内置 `-compdb`）
- Windows PowerShell 5.1（系统自带，无需额外安装）

## 注意事项

1. **低版本一键脚本使用 `-build` 全量重建**
   `-make` 只编译改动过的文件，日志里会缺少未变更文件的命令行，生成的数据库不完整。
   若确实想增量编译，请按“分步用法”自行执行，并接受数据库可能落后于工程配置。
2. **编码**（改动脚本时请保持）
   - `build_compile_commands.bat`：**GBK + CRLF**。cmd.exe 按本地代码页（936）解析；
     若保存成 UTF-8 或 LF 换行，会出现中文乱码、整行错位甚至 `set` 失效。
   - 三个 `.ps1`：**UTF-8 BOM**。PowerShell 5.1 对无 BOM 的 UTF-8
     会按本地代码页读取，导致中文显示乱码。
3. **IAR 专有参数**
   命令中含 `--no_cse`、`--dlib_config`、`-Om`、`-e` 等 IAR 专有选项，
   clangd 可能提示 `unknown argument`，但**不影响** `-I` / `-D` 的代码跳转与补全。
4. **进度显示**
   控制台的 `[编译] n/总数` 只是按日志增量统计出来的展示，不改变日志内容，
   也不影响结果；日志始终是 IarBuild 的原始输出。高版本 `-compdb` 不编译，
   只显示一行耗时。
5. **刷新时机**
   源码或工程选项（包含路径、宏定义、编译配置）变更后，需要重新运行本工具刷新
   `compile_commands.json`；文件位于工作区根目录，clangd 会自动发现。
6. **高版本不编译**
   `-compdb` / `-jsondb` 只读工程配置、不执行编译，所以不会顺带检查代码是否能编过；
   需要确认编译结果时用 `-Mode log`，或在 IAR 里正常编译一次。
6. **高版本解析失败会自动回退**
   `-jsondb` 的输出格式各版本不完全一致（字段名、是否含链接步骤都有差异），脚本按候选字段名宽松解析；
   若一条编译条目都提取不出来，`auto` 模式会自动改走“编译 + 日志解析”，
   并把 json 原文件路径、首条字段与内容打印出来；显式 `-Mode jsondb` 时则直接报错并保留 json 供排查。

## 验证生成结果

生成后可用 PowerShell 自检：

```powershell
$db = Get-Content .\compile_commands.json -Raw | ConvertFrom-Json
$db.Count                                        # 条目数
$db[0].arguments[0]                              # 应为对应版本的 iccarm.exe 绝对路径
($db | Where-Object { -not (Test-Path $_.file) }).Count   # 应为 0
```

条目数应等于工程实际编译的文件数（当前样例为 51 个 `.c` + 1 个 `.s` = **52**）。
