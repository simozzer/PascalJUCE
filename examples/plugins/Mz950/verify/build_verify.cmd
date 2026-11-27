@echo off
rem Mz950 - Created by Simon Moscrop
rem Free software under the GNU AGPL v3; see LICENSE.
rem
rem Builds and runs every equivalence check of the Pascal S950 engine against the ORIGINAL
rem C++ one (VirtualS950's Plugin/Source/S950, compiled as it is with clang-cl):
rem   verify_disk.cmd    reading every disk, every keygroup edit, the writing half, fuzzing
rem   verify_synth.cmd   waves, drums, mix plans, synth disks byte for byte, recipe text
rem   (here)             the audio: scenarios.txt through both engines, bit for bit
rem
rem   build_verify.cmd           all four
rem   build_verify.cmd audio     the audio check alone (it uses the disk check's RICH image,
rem                              so run the disk check once first)
rem   build_verify.cmd plugin    the plug-in check alone (PluginCheck.dpr: Mz950Plugin through
rem                              the library's entry point with a fake host; run last by default)
rem
rem   VS950_SRC  the C++ VirtualS950 repository (default %USERPROFILE%\src\VirtualS950), read only
rem   FPC        fpc.exe (default C:\lazarus64\fpc\3.2.2\bin\x86_64-win64\fpc.exe)
rem Output goes to %TEMP%\mz950-verify only.
rem
rem The C++ is built /MD, as the plug-in's CMake build is (CMake's default runtime): the DLL
rem Universal CRT is the one S950Math calls (ucrtbase.dll). The static CRT's pow differs from
rem it in the last bit for some arguments, so a /MT build would not be the plug-in.
setlocal
if "%VS950_SRC%"=="" set VS950_SRC=%USERPROFILE%\src\VirtualS950
if "%FPC%"=="" set FPC=C:\lazarus64\fpc\3.2.2\bin\x86_64-win64\fpc.exe
set HERE=%~dp0
set SRC=%VS950_SRC%\Plugin\Source\S950
set OUT=%TEMP%\mz950-verify\audio

if /i "%1"=="audio" goto audio
if /i "%1"=="plugin" goto plugin

echo ====================================================== disk
call "%HERE%verify_disk.cmd" || (echo build_verify: the disk check FAILED & exit /b 1)
echo ====================================================== synth
call "%HERE%verify_synth.cmd" || (echo build_verify: the synth check FAILED & exit /b 1)

:audio
echo ====================================================== audio
for %%D in (cpp pas chk obj units-o2 units-chk disks) do if not exist "%OUT%\%%D" mkdir "%OUT%\%%D"

copy /y "%VS950_SRC%\disks\*.hfe" "%OUT%\disks\" >nul || exit /b 1
copy /y "%TEMP%\mz950-verify\disk\img\rich_cpp.img" "%OUT%\disks\rich.img" >nul || (echo no RICH image: run the disk check first & exit /b 1)

call "C:\Program Files\Microsoft Visual Studio\18\Community\VC\Auxiliary\Build\vcvars64.bat" >nul || exit /b 1

echo === building the C++ reference (optimised, precise floating point, /MD)
clang-cl /nologo /std:c++17 /O2 /EHsc /MD /D_CRT_SECURE_NO_WARNINGS /I"%SRC%" ^
  "%HERE%render_cpp.cpp" "%SRC%\Engine.cpp" "%SRC%\Voice.cpp" "%SRC%\Disk.cpp" "%SRC%\Hfe.cpp" ^
  "%SRC%\Synth.cpp" "%SRC%\SynthPatch.cpp" ^
  /Fo"%OUT%\obj\\" /Fe"%OUT%\render_cpp.exe" || exit /b 1

echo === building the Pascal port: -O2 as the plug-in builds it, and with every check on
"%FPC%" -B -Mdelphi -FcUTF8 -O2 -vew -Fu"%HERE%.." -FU"%OUT%\units-o2" -FE"%OUT%" "%HERE%render_pas.dpr" >"%OUT%\fpc-o2.log" 2>&1 || (type "%OUT%\fpc-o2.log" & exit /b 1)
"%FPC%" -B -Mdelphi -FcUTF8 -O- -Cr -Co -Ct -CR -gl -gh -vew -Fu"%HERE%.." -FU"%OUT%\units-chk" -FE"%OUT%" -o"%OUT%\render_pas_chk.exe" "%HERE%render_pas.dpr" >"%OUT%\fpc-chk.log" 2>&1 || (type "%OUT%\fpc-chk.log" & exit /b 1)

echo === the C++
"%OUT%\render_cpp.exe" "%HERE%scenarios.txt" "%OUT%\disks" "%OUT%\cpp" || exit /b 1

echo === the Pascal, -O2
"%OUT%\render_pas.exe" "%HERE%scenarios.txt" "%OUT%\disks" "%OUT%\pas" || exit /b 1

echo === the Pascal, range/overflow/stack/object checks and heaptrc
"%OUT%\render_pas_chk.exe" "%HERE%scenarios.txt" "%OUT%\disks" "%OUT%\chk" >"%OUT%\chk.log" 2>&1
set CHK=%ERRORLEVEL%
findstr /c:"render_pas:" /c:"unfreed memory" /c:"Runtime error" /c:"Exception" "%OUT%\chk.log"
if not "%CHK%"=="0" (type "%OUT%\chk.log" & exit /b 1)
findstr /r /c:"^0 unfreed memory blocks" "%OUT%\chk.log" >nul || (echo heaptrc reports unfreed memory & exit /b 1)

echo === C++ against Pascal -O2
"%OUT%\render_pas.exe" --compare "%HERE%scenarios.txt" "%OUT%\cpp" "%OUT%\pas" || exit /b 1
echo === C++ against Pascal with checks
"%OUT%\render_pas.exe" --compare "%HERE%scenarios.txt" "%OUT%\cpp" "%OUT%\chk" >"%OUT%\compare-chk.log" || (type "%OUT%\compare-chk.log" & exit /b 1)
findstr /c:"compare:" "%OUT%\compare-chk.log"

if /i "%1"=="audio" goto passed

:plugin
echo ====================================================== plugin
rem Mz950Plugin and its units with every run-time check and heaptrc, through the real entry
rem point. With the panel (Mz950Editor) when it is there; without it (-dMZ950_NO_EDITOR,
rem CreateEditor nil) otherwise. Output only under %TEMP%\mz950-verify\plugin.
set POUT=%TEMP%\mz950-verify\plugin
if not exist "%POUT%\units" mkdir "%POUT%\units"
set NOEDITOR=
if not exist "%HERE%..\Mz950Editor.pas" (set NOEDITOR=-dMZ950_NO_EDITOR& echo === no Mz950Editor.pas: building without the panel)
"%FPC%" -B -Mdelphi -FcUTF8 -O- -Cr -Co -Ct -CR -gl -gh -vew %NOEDITOR% -Fu"%HERE%.." -Fu"%HERE%..\..\..\..\pascal" -FU"%POUT%\units" -FE"%POUT%" "%HERE%PluginCheck.dpr" >"%POUT%\fpc.log" 2>&1 || (type "%POUT%\fpc.log" & exit /b 1)
"%POUT%\PluginCheck.exe" >"%POUT%\check.log" 2>&1
set CHK=%ERRORLEVEL%
type "%POUT%\check.log"
if not "%CHK%"=="0" (echo build_verify: the plug-in check FAILED & exit /b 1)
findstr /r /c:"^0 unfreed memory blocks" "%POUT%\check.log" >nul || (echo heaptrc reports unfreed memory & exit /b 1)

:passed
echo build_verify: passed
exit /b 0
