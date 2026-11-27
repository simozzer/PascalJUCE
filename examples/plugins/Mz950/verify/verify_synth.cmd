@echo off
rem Mz950 - Created by Simon Moscrop
rem Free software under the GNU AGPL v3; see LICENSE.
rem
rem The synth equivalence check: S950Synth and S950SynthPatch against the ORIGINAL C++
rem Synth.cpp / SynthPatch.cpp (with Disk.cpp and Hfe.cpp), case for case - waves, drums,
rem the random generator, mix plans, rendered disk images byte for byte, recipe text.
rem   VS950_SRC  the C++ VirtualS950 repository (default %USERPROFILE%\src\VirtualS950), read only
rem   FPC        fpc.exe (default C:\lazarus64\fpc\3.2.2\bin\x86_64-win64\fpc.exe)
rem Output goes to %TEMP%\mz950-verify\synth only. Exit code non-zero on any failure.
rem
rem The C++ reference is built /MD, as the plug-in's CMake build is (CMake's default runtime):
rem the DLL Universal CRT's pow is the one the Pascal calls (ucrtbase.dll). The static CRT
rem (/MT) has a pow that differs from it in the last bit for some arguments; that build is
rem compared too, for information only.
setlocal
if "%VS950_SRC%"=="" set VS950_SRC=%USERPROFILE%\src\VirtualS950
if "%FPC%"=="" set FPC=C:\lazarus64\fpc\3.2.2\bin\x86_64-win64\fpc.exe
set HERE=%~dp0
set SRC=%VS950_SRC%\Plugin\Source\S950
set OUT=%TEMP%\mz950-verify\synth
for %%D in (obj-md obj-mt units-o2 units-chk) do if not exist "%OUT%\%%D" mkdir "%OUT%\%%D"

call "C:\Program Files\Microsoft Visual Studio\18\Community\VC\Auxiliary\Build\vcvars64.bat" >nul || exit /b 1

echo === building the C++ reference
clang-cl /nologo /std:c++17 /O2 /EHsc /MD /D_CRT_SECURE_NO_WARNINGS /I"%SRC%" ^
  "%HERE%synth_cpp.cpp" "%SRC%\Synth.cpp" "%SRC%\SynthPatch.cpp" "%SRC%\Disk.cpp" "%SRC%\Hfe.cpp" ^
  /Fo"%OUT%\obj-md\\" /Fe"%OUT%\synth_cpp.exe" || exit /b 1
clang-cl /nologo /std:c++17 /O2 /EHsc /MT /D_CRT_SECURE_NO_WARNINGS /I"%SRC%" ^
  "%HERE%synth_cpp.cpp" "%SRC%\Synth.cpp" "%SRC%\SynthPatch.cpp" "%SRC%\Disk.cpp" "%SRC%\Hfe.cpp" ^
  /Fo"%OUT%\obj-mt\\" /Fe"%OUT%\synth_cpp_mt.exe" || exit /b 1

echo === building the Pascal port: -O2 as the plug-in builds it, and with every check on
"%FPC%" -B -Mdelphi -FcUTF8 -O2 -vew -Fu"%HERE%.." -FU"%OUT%\units-o2" -FE"%OUT%" "%HERE%synth_pas.dpr" >"%OUT%\fpc-o2.log" 2>&1 || (type "%OUT%\fpc-o2.log" & exit /b 1)
"%FPC%" -B -Mdelphi -FcUTF8 -O- -Cr -Co -Ct -CR -gl -gh -vew -Fu"%HERE%.." -FU"%OUT%\units-chk" -FE"%OUT%" -o"%OUT%\synth_pas_chk.exe" "%HERE%synth_pas.dpr" >"%OUT%\fpc-chk.log" 2>&1 || (type "%OUT%\fpc-chk.log" & exit /b 1)

echo === the C++
"%OUT%\synth_cpp.exe" "%OUT%\synth_cpp.txt" || exit /b 1
"%OUT%\synth_cpp_mt.exe" "%OUT%\synth_cpp_mt.txt" || exit /b 1

echo === the Pascal, -O2, against the C++
"%OUT%\synth_pas.exe" "%OUT%\synth_cpp.txt" "%OUT%\synth_pas.txt" || exit /b 1

echo === the Pascal, range/overflow/stack/object checks and heaptrc, against the C++
"%OUT%\synth_pas_chk.exe" "%OUT%\synth_cpp.txt" "%OUT%\synth_pas_chk.txt" >"%OUT%\chk.log" 2>&1
set CHK=%ERRORLEVEL%
type "%OUT%\chk.log"
if not "%CHK%"=="0" exit /b 1
findstr /r /c:"^0 unfreed memory blocks" "%OUT%\chk.log" >nul || (echo heaptrc reports unfreed memory & exit /b 1)
fc /b "%OUT%\synth_pas.txt" "%OUT%\synth_pas_chk.txt" >nul || (echo the -O2 and checked builds differ & exit /b 1)
echo   -O2 and checked builds: identical output

echo === for information: the C++ built /MT (static CRT pow) against the same Pascal output
"%OUT%\synth_pas.exe" --compare "%OUT%\synth_cpp_mt.txt" "%OUT%\synth_pas.txt" | findstr /c:"synth check"

echo verify_synth: passed
exit /b 0
