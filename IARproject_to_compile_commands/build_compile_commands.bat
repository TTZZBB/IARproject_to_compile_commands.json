@echo off
setlocal EnableExtensions EnableDelayedExpansion

rem ============================================================
rem  一键：识别 IAR 与工程，编译并生成 compile_commands.json
rem ------------------------------------------------------------
rem  用法：
rem    build_compile_commands.bat                自动识别；多个 .ewp 时列出编号让你选
rem    build_compile_commands.bat -List          只列出识别到的 IAR 和 .ewp
rem    build_compile_commands.bat -Manual        不自动识别，必须配 -Ewp 与 -IarRoot
rem    build_compile_commands.bat -Ewp FILE      指定 .ewp 工程
rem    build_compile_commands.bat -IarRoot DIR   指定 IAR 安装目录
rem    build_compile_commands.bat -Config Debug  指定构建配置
rem    build_compile_commands.bat -Mode compdb   强制方式（auto/compdb/jsondb/log）
rem    build_compile_commands.bat -NoPause       结束后直接退出（脚本/CI 用）
rem ------------------------------------------------------------
rem  高版本 IAR（iarbuild 支持 -compdb / -jsondb）直接由 IAR 生成，不编译；
rem  低版本 IAR（如 7.5，只有 -build / -make）先编译再用脚本解析日志。
rem  老工程必须用老版本 IAR 编译时，加 -Manual -IarRoot <7.5 目录> 锁死版本。
rem ============================================================

set "TOOLS=%~dp0"

powershell -NoProfile -ExecutionPolicy Bypass -File "%TOOLS%build_compile_commands.ps1" %*
set "RC=%ERRORLEVEL%"

if not "%RC%"=="0" echo [ERROR] 生成 compile_commands.json 失败（退出码 %RC%）

rem 双击运行时窗口会立即关闭，这里停住等回车；脚本/CI 调用请加 -NoPause
set "PAUSE_OFF="
set "ARGS=%*"
if defined ARGS (
  set "STRIPPED=!ARGS:-NoPause=!"
  if not "!STRIPPED!"=="!ARGS!" set "PAUSE_OFF=1"
)
if defined PAUSE_OFF exit /b %RC%
if defined NO_PAUSE exit /b %RC%

echo.
set "PAUSE_KEY="
set /p "PAUSE_KEY=按回车键退出 ..."
exit /b %RC%
