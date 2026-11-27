@echo off
rem MzPCG - Created by Simon Moscrop
rem Free software under the GNU AGPL v3; see LICENSE.
rem
rem Builds and runs the equivalence check (the Pascal engine against the original C++ one,
rem bit for bit) and the plug-in checks.
rem   MZPCG_SRC  the C++ MzPCG repository (default %USERPROFILE%\src\MzPCG), read only
rem   MZPCF_SRC  the C++ MzPCF repository, whose Source/PCF the C++ MzPCG compiles (default
rem              %USERPROFILE%\src\MzPCF), read only
rem   FPC        fpc.exe (default C:\lazarus64\fpc\3.2.2\bin\x86_64-win64\fpc.exe)
rem Output goes to %TEMP%\mzpcg-verify.
setlocal
if "%MZPCG_SRC%"=="" set MZPCG_SRC=%USERPROFILE%\src\MzPCG
if "%MZPCF_SRC%"=="" set MZPCF_SRC=%USERPROFILE%\src\MzPCF
if "%FPC%"=="" set FPC=C:\lazarus64\fpc\3.2.2\bin\x86_64-win64\fpc.exe
set HERE=%~dp0
set OUT=%TEMP%\mzpcg-verify
if not exist "%OUT%\cpp" mkdir "%OUT%\cpp"
if not exist "%OUT%\pas" mkdir "%OUT%\pas"
if not exist "%OUT%\units" mkdir "%OUT%\units"

call "C:\Program Files\Microsoft Visual Studio\18\Community\VC\Auxiliary\Build\vcvars64.bat" >nul || exit /b 1

rem The original engine, as its own build compiles it: optimised, precise floating point,
rem Source/PCG with MzPCF's Source/PCF.
clang-cl /nologo /std:c++17 /O2 /EHsc /MT /I"%MZPCG_SRC%\Source\PCG" /I"%MZPCF_SRC%\Source" ^
  "%HERE%render_cpp.cpp" "%MZPCG_SRC%\Source\PCG\Pcg.cpp" "%MZPCF_SRC%\Source\PCF\Pcf.cpp" ^
  /Fo"%OUT%\\" /Fe"%OUT%\render_cpp.exe" || exit /b 1

rem The port, compiled as the plug-in's Release build compiles it (-O2), and the plug-in
rem checks with every run-time check on. MzPCF's shared units come from ../../MzPCF/PCF.
"%FPC%" -B -Mdelphi -FcUTF8 -O2 -vewn -Fu"%HERE%.." -Fu"%HERE%..\PCG" -Fu"%HERE%..\..\MzPCF\PCF" -FU"%OUT%\units" -FE"%OUT%" "%HERE%render_pas.dpr" || exit /b 1
"%FPC%" -B -Mdelphi -FcUTF8 -O- -Cr -Co -Ct -CR -gl -gh -vewn -Fu"%HERE%.." -Fu"%HERE%..\PCG" -Fu"%HERE%..\..\MzPCF\PCF" -Fu"%HERE%..\..\..\..\pascal" -FU"%OUT%\units" -FE"%OUT%" "%HERE%PluginCheck.dpr" || exit /b 1

"%OUT%\render_cpp.exe" "%HERE%scenarios.txt" "%OUT%\cpp" || exit /b 1
"%OUT%\render_pas.exe" "%HERE%scenarios.txt" "%OUT%\pas" || exit /b 1
"%OUT%\render_pas.exe" --compare "%HERE%scenarios.txt" "%OUT%\cpp" "%OUT%\pas" || exit /b 1
"%OUT%\PluginCheck.exe" || exit /b 1
