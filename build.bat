@echo off
rem build.bat              debug build of the app, build\windows\tidalfast.exe
rem build.bat release      optimized build, with the windows subsystem
rem build.bat libs         only the C libraries, into build\windows
rem build.bat dist         release build in build\dist\tidalfast.exe
rem
rem Builds on Windows itself. Run it from a "x64 Native Tools Command Prompt"
rem for Visual Studio, so cl, lib, rc and link are on PATH, with odin and
rem glslangValidator (from the Vulkan SDK) on PATH too. curl and tar come
rem with Windows 10 and later. TIDALFAST_VERSION=1.2.3 sets the version.
rem build.sh windows cross-builds the same executable from macOS or Linux.
setlocal EnableExtensions EnableDelayedExpansion
cd /d "%~dp0"

set mode=debug
set target=all
:args
if "%~1"=="" goto args_done
if /i "%~1"=="release" (set mode=release) else if /i "%~1"=="libs" (set target=libs) else if /i "%~1"=="dist" (set target=dist& set mode=release) else (
	echo usage: %~nx0 [release] ^| %~nx0 libs ^| %~nx0 dist 1>&2
	exit /b 1
)
shift
goto args
:args_done

where cl >nul 2>nul || (echo %~nx0: cl isn't on PATH, run this from a x64 Native Tools Command Prompt 1>&2 & exit /b 1)
if not "%VSCMD_ARG_TGT_ARCH%"=="" if /i not "%VSCMD_ARG_TGT_ARCH%"=="x64" (echo %~nx0: the prompt targets %VSCMD_ARG_TGT_ARCH%, use the x64 one 1>&2 & exit /b 1)

if "%mode%"=="release" (
	set odin_flags=-o:speed
	set cl_opt=/O2
	set subsystem=windows
) else (
	set odin_flags=-debug
	set cl_opt=/Od /Z7
	set subsystem=console
)

set commit=unknown
for /f %%c in ('git rev-parse HEAD 2^>nul') do set commit=%%c
if not "%commit%"=="unknown" (
	git diff --quiet HEAD 2>nul || set commit=!commit!-dirty
)

set version=%TIDALFAST_VERSION%
if "%version%"=="" for /f %%v in ('git describe --tags --exact-match --match "v[0-9]*" 2^>nul') do set version=%%v
if "%version%"=="" set version=0.0.0
if "%version:~0,1%"=="v" set version=%version:~1%

if not exist build\windows mkdir build\windows

call :lib kbts kb_text_shape || exit /b 1
call :lib miniaudio miniaudio || exit /b 1
call :lib dr_flac dr_flac || exit /b 1
call :freetype || exit /b 1
if "%target%"=="libs" exit /b 0

if not exist build\shaders mkdir build\shaders
for %%s in (src\render\shaders\*.vert src\render\shaders\*.frag) do (
	glslangValidator -V --quiet "%%s" -o "build\shaders\%%~nxs.spv" || exit /b 1
)

rem The icon and the version go into the executable as resources.
if not exist build\windows\shell mkdir build\windows\shell
set version_commas=%version:.=,%,0
powershell -NoProfile -Command "(Get-Content -Raw 'packaging\windows\tidalfast.rc').Replace('@VERSION_COMMAS@','%version_commas%').Replace('@VERSION@','%version%') | Set-Content -NoNewline 'build\windows\shell\tidalfast.rc'" || exit /b 1
copy /y packaging\windows\tidalfast.ico build\windows\shell\ >nul
copy /y packaging\windows\tidalfast.manifest build\windows\shell\ >nul
rc /nologo /fo build\windows\shell\tidalfast.res build\windows\shell\tidalfast.rc || exit /b 1
set objects=
for %%c in (shell\shell_win32.c shell\common.c) do (
	cl /nologo /c /MT /W3 /std:c11 /experimental:c11atomics %cl_opt% /Ishell "%%c" /Fobuild\windows\shell\%%~nc.obj || exit /b 1
	set objects=!objects! build\windows\shell\%%~nc.obj
)

set out=build\windows\tidalfast.exe
if "%target%"=="dist" (
	if not exist build\dist mkdir build\dist
	set out=build\dist\tidalfast.exe
)
odin build src\app -out:%out% -target:windows_amd64 -vet -strict-style %odin_flags% -define:TIDALFAST_COMMIT=%commit% ^
	-extra-linker-flags:"/subsystem:%subsystem% /ignore:4099 %objects% build\windows\shell\tidalfast.res user32.lib gdi32.lib imm32.lib dwmapi.lib shell32.lib ole32.lib advapi32.lib psapi.lib" || exit /b 1
exit /b 0

rem A C library from third_party into build\windows\<name>\<lib>.lib, which
rem its Odin binding links. Delete the folder to rebuild it.
:lib
if exist build\windows\%1\%2.lib exit /b 0
if not exist build\windows\%1 mkdir build\windows\%1
cl /nologo /c /MT /W3 /std:c11 /experimental:c11atomics /O2 third_party\%1\%2.c /Fobuild\windows\%1\%2.obj || exit /b 1
lib /nologo /out:build\windows\%1\%2.lib build\windows\%1\%2.obj || exit /b 1
del build\windows\%1\%2.obj
exit /b 0

rem FreeType 2.13.3 from its release, with the modules and options in
rem third_party\freetype.
:freetype
if exist build\windows\freetype\freetype.lib exit /b 0
set ft=build\windows\freetype-2.13.3
if not exist %ft% (
	curl -fsSL -o %ft%.tar.xz https://download.savannah.gnu.org/releases/freetype/freetype-2.13.3.tar.xz || exit /b 1
	set hash=
	for /f "skip=1 delims=" %%h in ('certutil -hashfile %ft%.tar.xz SHA256') do if not defined hash set hash=%%h
	set hash=!hash: =!
	if /i not "!hash!"=="0550350666d427c74daeb85d5ac7bb353acba5f76956395995311a9c6f063289" (
		echo %~nx0: freetype-2.13.3.tar.xz doesn't match its SHA-256 1>&2
		del %ft%.tar.xz
		exit /b 1
	)
	tar xf %ft%.tar.xz -C build\windows || exit /b 1
	del %ft%.tar.xz
)
if not exist build\windows\freetype\obj mkdir build\windows\freetype\obj
for %%c in (base\ftsystem.c base\ftinit.c base\ftdebug.c base\ftbase.c base\ftbbox.c base\ftbitmap.c base\ftmm.c truetype\truetype.c cff\cff.c sfnt\sfnt.c psaux\psaux.c psnames\psnames.c pshinter\pshinter.c smooth\smooth.c) do (
	cl /nologo /c /MT /W0 /O2 /I%ft%\include /Ithird_party\freetype /DFT2_BUILD_LIBRARY "/DFT_CONFIG_MODULES_H=<tf_ftmodule.h>" "/DFT_CONFIG_OPTIONS_H=<tf_ftoption.h>" %ft%\src\%%c /Fobuild\windows\freetype\obj\%%~nc.obj || exit /b 1
)
lib /nologo /out:build\windows\freetype\freetype.lib build\windows\freetype\obj\*.obj || exit /b 1
rmdir /s /q build\windows\freetype\obj
exit /b 0
