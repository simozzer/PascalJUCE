@echo off
rem Mz101 - Created by Simon Moscrop
rem Free software under the GNU AGPL v3; see LICENSE.
rem
rem Builds mz101_host_check (in %TEMP%\mz101-host) and loads the built VST3 and LV2
rem bundles with it. Build PascalJUCE (Release) first. Needs cmake on PATH.
setlocal
set HERE=%~dp0
set ROOT=%HERE%..\..\..\..
set BUNDLES=%ROOT%\build\x64-clang\examples\plugins\Mz101\Mz101_artefacts\Release
cmake -S "%HERE%host" -B "%TEMP%\mz101-host" -G "Visual Studio 18 2026" -A x64 -T ClangCL || exit /b 1
cmake --build "%TEMP%\mz101-host" --config Release -- -m || exit /b 1
set EXE=%TEMP%\mz101-host\mz101_host_check_artefacts\Release\mz101_host_check.exe
"%EXE%" VST3 "%BUNDLES%\VST3\Mz101_Pascal.vst3" || exit /b 1
"%EXE%" LV2 "%BUNDLES%\LV2\Mz101_Pascal.lv2" || exit /b 1
