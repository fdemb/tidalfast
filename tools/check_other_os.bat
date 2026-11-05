@echo off
rem Type-checks the app and the measure tool for Linux and macOS from
rem Windows. The C library bindings, this project's and Odin's STB, refuse
rem to compile without their .a files, so empty ones stand in while it
rem checks. Only files this script made are removed.
setlocal EnableDelayedExpansion
cd /d "%~dp0\.."
for /f "delims=" %%r in ('odin root') do set root=%%r
set made=
for %%l in (build\dr_flac\dr_flac.a build\kbts\kb_text_shape.a build\miniaudio\miniaudio.a) do call :stub "%%l"
for %%l in (stb_image stb_image_write stb_image_resize stb_rect_pack) do (
	call :stub "!root!vendor\stb\lib\%%l.a"
	call :stub "!root!vendor\stb\lib\darwin\%%l.a"
)
set failed=0
for %%t in (linux_amd64 darwin_arm64) do (
	echo %%t
	odin check src\app -no-entry-point -vet -strict-style -target:%%t || set failed=1
	odin check tools\measure -vet -strict-style -target:%%t || set failed=1
)
for %%f in (!made!) do del %%f
exit /b %failed%

:stub
if exist %1 exit /b 0
if not exist "%~dp1" mkdir "%~dp1"
type nul > %1
set made=!made! %1
exit /b 0
