@echo off
rem Mz808 - Created by Simon Moscrop
rem Free software under the GNU AGPL v3; see LICENSE.
rem
rem Builds and runs the equivalence check (the Pascal engine against the original C++ one)
rem and the plug-in checks.
rem   MZ808_SRC  the C++ Mz808 repository (default %USERPROFILE%\src\Mz808), read only
rem   FPC        fpc.exe (default C:\lazarus64\fpc\3.2.2\bin\x86_64-win64\fpc.exe)
rem Output goes to %TEMP%\mz808-verify.
setlocal
if "%MZ808_SRC%"=="" set MZ808_SRC=%USERPROFILE%\src\Mz808
if "%FPC%"=="" set FPC=C:\lazarus64\fpc\3.2.2\bin\x86_64-win64\fpc.exe
set HERE=%~dp0
set OUT=%TEMP%\mz808-verify
if not exist "%OUT%\cpp" mkdir "%OUT%\cpp"
if not exist "%OUT%\pas" mkdir "%OUT%\pas"
if not exist "%OUT%\units" mkdir "%OUT%\units"

call "C:\Program Files\Microsoft Visual Studio\18\Community\VC\Auxiliary\Build\vcvars64.bat" >nul || exit /b 1

rem The original engine, as its own build compiles it: optimised, precise floating point.
clang-cl /nologo /std:c++17 /O2 /EHsc /MT /I"%MZ808_SRC%\Source\TR808" ^
  "%HERE%render_cpp.cpp" "%MZ808_SRC%\Source\TR808\Engine.cpp" ^
  /Fo"%OUT%\\" /Fe"%OUT%\render_cpp.exe" || exit /b 1

rem The port, compiled as the plug-in's Release build compiles it (-O2), and the plug-in
rem checks with every run-time check on.
"%FPC%" -B -Mdelphi -FcUTF8 -O2 -vewn -Fu"%HERE%.." -FU"%OUT%\units" -FE"%OUT%" "%HERE%render_pas.dpr" || exit /b 1
"%FPC%" -B -Mdelphi -FcUTF8 -O- -Cr -Co -Ct -CR -gl -gh -vewn -Fu"%HERE%.." -Fu"%HERE%..\..\..\..\pascal" -FU"%OUT%\units" -FE"%OUT%" "%HERE%PluginCheck.dpr" || exit /b 1

"%OUT%\render_cpp.exe" "%HERE%scenarios.txt" "%MZ808_SRC%\Source\Presets.cpp" "%OUT%\cpp" || exit /b 1
"%OUT%\render_pas.exe" "%HERE%scenarios.txt" "%OUT%\pas" || exit /b 1
"%OUT%\render_pas.exe" --compare "%HERE%scenarios.txt" "%OUT%\cpp" "%OUT%\pas" || exit /b 1
"%OUT%\PluginCheck.exe" || exit /b 1
