@echo off
rem Builds native/build/gmcl_pba_win64.dll (needs VS 2022+ C++ tools, CMake, Ninja).
rem VCVARS: path of vcvars64.bat (default below).
if not defined VCVARS set "VCVARS=C:\Program Files\Microsoft Visual Studio\18\Community\VC\Auxiliary\Build\vcvars64.bat"
call "%VCVARS%" >nul || exit /b 1
cmake -S "%~dp0." -B "%~dp0build" -G Ninja -DCMAKE_BUILD_TYPE=Release || exit /b 1
cmake --build "%~dp0build" || exit /b 1
