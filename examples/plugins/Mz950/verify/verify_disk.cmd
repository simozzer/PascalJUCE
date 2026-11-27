@echo off
rem Mz950 - Created by Simon Moscrop
rem Free software under the GNU AGPL v3; see LICENSE.
rem
rem Holds S950Disk and S950Hfe to the original C++ Disk.cpp and Hfe.cpp:
rem   1. reading - every disk image, and the images the writing check builds, dumped by both
rem      (every entry, keygroup, setting, sample and patch) and the dumps compared;
rem   2. editing and writing - DiskEditCheck's checks run by both, every setting of every
rem      keygroup at eight values, the bytes each edit moved compared, and every image either
rem      side builds or edits compared byte for byte;
rem   3. hostile input - fuzz_pas feeds thousands of random and mutated images to the port
rem      with every run-time check on; a sample of them is dumped by both and compared, and
rem      the C++ is run over them again under AddressSanitizer (if clang's runtime is found).
rem Exits non-zero on any mismatch, failure, exception or leak.
rem
rem   S950_SRC    the C++ sources (default %USERPROFILE%\src\VirtualS950\Plugin\Source\S950), read only
rem   S950_DISKS  the disk images (default %USERPROFILE%\src\VirtualS950\disks), *.hfe and *.img
rem   FPC         fpc.exe (default C:\lazarus64\fpc\3.2.2\bin\x86_64-win64\fpc.exe)
rem   FUZZ_CASES  how many fuzz cases (default 3000)
rem Output goes to %TEMP%\mz950-verify\disk only.
setlocal
if "%S950_SRC%"=="" set S950_SRC=%USERPROFILE%\src\VirtualS950\Plugin\Source\S950
if "%S950_DISKS%"=="" set S950_DISKS=%USERPROFILE%\src\VirtualS950\disks
if "%FPC%"=="" set FPC=C:\lazarus64\fpc\3.2.2\bin\x86_64-win64\fpc.exe
if "%FUZZ_CASES%"=="" set FUZZ_CASES=3000
set HERE=%~dp0
set OUT=%TEMP%\mz950-verify\disk
if not exist "%OUT%\units" mkdir "%OUT%\units"
if not exist "%OUT%\obj" mkdir "%OUT%\obj"
if not exist "%OUT%\img" mkdir "%OUT%\img"
if not exist "%OUT%\fuzz" mkdir "%OUT%\fuzz"
del /q "%OUT%\img\*" "%OUT%\fuzz\*" 2>nul

rem The disks.
if exist "%OUT%\disks.txt" del "%OUT%\disks.txt"
for %%f in ("%S950_DISKS%\*.hfe" "%S950_DISKS%\*.img") do echo %%~ff>>"%OUT%\disks.txt"
if not exist "%OUT%\disks.txt" (echo verify_disk: no disk images in %S950_DISKS% & exit /b 1)

call "C:\Program Files\Microsoft Visual Studio\18\Community\VC\Auxiliary\Build\vcvars64.bat" >nul || exit /b 1

echo == building
rem The original reader and writer, as the plug-in's build compiles them.
clang-cl /nologo /std:c++17 /O2 /EHsc /MT /D_CRT_SECURE_NO_WARNINGS /I"%S950_SRC%" ^
  "%HERE%disk_cpp.cpp" "%S950_SRC%\Disk.cpp" "%S950_SRC%\Hfe.cpp" ^
  /Fo"%OUT%\obj\\" /Fe"%OUT%\disk_cpp.exe" || exit /b 1
clang-cl /nologo /std:c++17 /O2 /EHsc /MT /D_CRT_SECURE_NO_WARNINGS /I"%S950_SRC%" ^
  "%HERE%diskedit_cpp.cpp" "%S950_SRC%\Disk.cpp" "%S950_SRC%\Hfe.cpp" ^
  /Fo"%OUT%\obj\\" /Fe"%OUT%\diskedit_cpp.exe" || exit /b 1

rem The port, with every run-time check on and the heap tracer; its own unit directory.
set FPCOPT=-B -Mdelphi -FcUTF8 -O- -Cr -Co -Ct -CR -gl -gh -vewn -Fu"%HERE%.." -FU"%OUT%\units" -FE"%OUT%"
"%FPC%" %FPCOPT% "%HERE%disk_pas.dpr" >"%OUT%\fpc.log" 2>&1 || (type "%OUT%\fpc.log" & exit /b 1)
"%FPC%" %FPCOPT% "%HERE%diskedit_pas.dpr" >"%OUT%\fpc.log" 2>&1 || (type "%OUT%\fpc.log" & exit /b 1)
rem (The fuzz at -O2, its checks still on: it runs thousands of cases.)
"%FPC%" %FPCOPT% -O2 "%HERE%fuzz_pas.dpr" >"%OUT%\fpc.log" 2>&1 || (type "%OUT%\fpc.log" & exit /b 1)
rem And the units once more as the plug-in's Release build compiles them, for warnings.
"%FPC%" -B -Mdelphi -FcUTF8 -O2 -vewn -Fu"%HERE%.." -FU"%OUT%\units" -FE"%OUT%" "%HERE%..\S950Disk.pas" >"%OUT%\fpc.log" 2>&1 || (type "%OUT%\fpc.log" & exit /b 1)

echo == editing and writing
"%OUT%\diskedit_cpp.exe" "%OUT%\edit_cpp.txt" "%OUT%\img" cpp @"%OUT%\disks.txt" || exit /b 1
"%OUT%\diskedit_pas.exe" "%OUT%\edit_pas.txt" "%OUT%\img" pas @"%OUT%\disks.txt" >"%OUT%\diskedit_pas.log" 2>&1
set RC=%ERRORLEVEL%
findstr /b /c:"diskedit_pas:" /c:"  FAIL" "%OUT%\diskedit_pas.log"
call :heap "%OUT%\diskedit_pas.log" diskedit_pas || exit /b 1
if not "%RC%"=="0" exit /b 1
"%OUT%\disk_pas.exe" --compare edits "%OUT%\edit_cpp.txt" "%OUT%\edit_pas.txt" >"%OUT%\compare.log" 2>&1
set RC=%ERRORLEVEL%
call :summary "%OUT%\compare.log"
if not "%RC%"=="0" exit /b 1
set IMAGES=0
for %%f in ("%OUT%\img\*_cpp.img") do call :sameimage "%%~ff" || exit /b 1
echo   %IMAGES% images built or edited, all identical byte for byte

echo == reading
rem The disks, and the disks the writing check built (the C++ side's: identical to the Pascal's).
copy /y "%OUT%\disks.txt" "%OUT%\read.txt" >nul
for %%f in (built hd open rich) do echo %OUT%\img\%%f_cpp.img>>"%OUT%\read.txt"
"%OUT%\disk_cpp.exe" "%OUT%\read_cpp.txt" @"%OUT%\read.txt" || exit /b 1
"%OUT%\disk_pas.exe" "%OUT%\read_pas.txt" @"%OUT%\read.txt" >"%OUT%\disk_pas.log" 2>&1 || (type "%OUT%\disk_pas.log" & exit /b 1)
call :heap "%OUT%\disk_pas.log" disk_pas || exit /b 1
"%OUT%\disk_pas.exe" --compare reading "%OUT%\read_cpp.txt" "%OUT%\read_pas.txt" >"%OUT%\compare.log" 2>&1
set RC=%ERRORLEVEL%
call :summary "%OUT%\compare.log"
if not "%RC%"=="0" exit /b 1
call :counts "%OUT%\read_cpp.txt"

echo == hostile input
"%OUT%\fuzz_pas.exe" "%OUT%\fuzz" %FUZZ_CASES% 950 @"%OUT%\disks.txt" >"%OUT%\fuzz_pas.log" 2>&1
set RC=%ERRORLEVEL%
findstr /b /c:"  kinds" /c:"fuzz_pas:" /c:"  case" "%OUT%\fuzz_pas.log"
call :heap "%OUT%\fuzz_pas.log" fuzz_pas || exit /b 1
if not "%RC%"=="0" exit /b 1
"%OUT%\disk_cpp.exe" "%OUT%\fuzz_cpp.txt" @"%OUT%\fuzz\list.txt" || (echo   the C++ failed on a fuzz case & exit /b 1)
"%OUT%\disk_pas.exe" "%OUT%\fuzz_pas.txt" @"%OUT%\fuzz\list.txt" >"%OUT%\disk_pas.log" 2>&1 || (type "%OUT%\disk_pas.log" & exit /b 1)
call :heap "%OUT%\disk_pas.log" disk_pas-on-the-fuzz-cases || exit /b 1
"%OUT%\disk_pas.exe" --compare "fuzz cases" "%OUT%\fuzz_cpp.txt" "%OUT%\fuzz_pas.txt" >"%OUT%\compare.log" 2>&1
set RC=%ERRORLEVEL%
call :summary "%OUT%\compare.log"
if not "%RC%"=="0" exit /b 1
call :counts "%OUT%\fuzz_cpp.txt"

rem The C++ itself under AddressSanitizer on the same cases and the disks: an out-of-bounds
rem read in the original would stop it here. Skipped if clang's ASan runtime is not found.
set ASANDIR=
for /d %%v in ("%VCINSTALLDIR%Tools\Llvm\x64\lib\clang\*") do if exist "%%~v\lib\windows\clang_rt.asan_dynamic-x86_64.dll" set ASANDIR=%%~v\lib\windows
if "%ASANDIR%"=="" (echo   AddressSanitizer runtime not found: the C++ ASan pass skipped & goto :done)
if not exist "%OUT%\asan" mkdir "%OUT%\asan"
clang-cl /nologo /std:c++17 /O1 /EHsc /MT -fsanitize=address /D_CRT_SECURE_NO_WARNINGS /I"%S950_SRC%" ^
  "%HERE%disk_cpp.cpp" "%S950_SRC%\Disk.cpp" "%S950_SRC%\Hfe.cpp" ^
  /Fo"%OUT%\asan\\" /Fe"%OUT%\asan\disk_cpp_asan.exe" || exit /b 1
set PATH=%ASANDIR%;%PATH%
"%OUT%\asan\disk_cpp_asan.exe" "%OUT%\asan\fuzz_asan.txt" @"%OUT%\fuzz\list.txt" >nul || (echo   the C++ failed under ASan & exit /b 1)
"%OUT%\asan\disk_cpp_asan.exe" "%OUT%\asan\read_asan.txt" @"%OUT%\read.txt" >nul || (echo   the C++ failed under ASan & exit /b 1)
fc /b "%OUT%\asan\fuzz_asan.txt" "%OUT%\fuzz_cpp.txt" >nul || (echo   the C++ under ASan read the fuzz cases differently & exit /b 1)
fc /b "%OUT%\asan\read_asan.txt" "%OUT%\read_cpp.txt" >nul || (echo   the C++ under ASan read the disks differently & exit /b 1)
echo   the C++ under AddressSanitizer: clean on every fuzz case and disk, and the same dumps

:done
echo verify_disk: all passed
exit /b 0

rem ---------------------------------------------------------------------------------

rem The heap tracer's verdict: "0 unfreed memory blocks", or a failure.
:heap
findstr /c:" unfreed memory blocks" "%~1" >"%OUT%\heap.txt"
set /p HEAPLINE=<"%OUT%\heap.txt"
findstr /b /c:"0 unfreed memory blocks : 0" "%~1" >nul || (echo   %~2: LEAK - %HEAPLINE% & type "%~1" & exit /b 1)
echo   %~2: %HEAPLINE%
exit /b 0

rem The comparison's verdict, and the differences if any.
:summary
findstr /v /c:"memory blocks" /c:"Heap dump" /c:"True heap" /c:"True free" "%~1"
exit /b 0

rem What a dump held.
:counts
setlocal
for /f %%n in ('findstr /b /c:"file " "%~1" ^| find /c /v ""') do set FILES=%%n
for /f %%n in ('findstr /b /c:"load ok" "%~1" ^| find /c /v ""') do set OK=%%n
for /f %%n in ('findstr /b /c:"entry " "%~1" ^| find /c /v ""') do set ENTRIES=%%n
for /f %%n in ('findstr /b /c:"   kg " "%~1" ^| find /c /v ""') do set KGS=%%n
for /f %%n in ('findstr /b /c:"  get " "%~1" ^| find /c /v ""') do set GETS=%%n
for /f %%n in ('findstr /b /c:"  patch '" "%~1" ^| find /c /v ""') do set PATCHES=%%n
for /f %%n in ('findstr /b /c:"   sound " "%~1" ^| find /c /v ""') do set SOUNDS=%%n
for /f %%n in ('findstr /b /c:"   pk " "%~1" ^| find /c /v ""') do set PKS=%%n
echo   %FILES% images (%OK% loaded), %ENTRIES% entries, %KGS% keygroups, %GETS% keygroups x 38 settings read, %PATCHES% patches, %PKS% patch entries, %SOUNDS% sounds
endlocal
exit /b 0

rem One image the C++ wrote against the Pascal's.
:sameimage
set A=%~1
set B=%A:_cpp.img=_pas.img%
if not exist "%B%" (echo   missing %B% & exit /b 1)
fc /b "%A%" "%B%" >nul || (echo   image mismatch: %~nx1 & exit /b 1)
set /a IMAGES+=1
exit /b 0
