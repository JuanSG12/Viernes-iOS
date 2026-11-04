@echo off
rem Ejecuta cualquier comando de Swift en Windows con el entorno de Visual Studio Build Tools cargado.
rem Uso:  scripts\swift-windows.cmd swift test
set "SWIFTBIN=%LOCALAPPDATA%\Programs\Swift\Toolchains\6.4.2+Asserts\usr\bin"
set "VCVARS=%ProgramFiles(x86)%\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
if not exist "%VCVARS%" (echo No se encontro vcvars64.bat: instala las Build Tools de VS 2022 con C++ & exit /b 2)
call "%VCVARS%" >nul
set "SDKROOT=%LOCALAPPDATA%\Programs\Swift\Platforms\6.4.2\Windows.platform\Developer\SDKs\Windows.sdk"
set "PATH=%SWIFTBIN%;%PATH%"
cd /d "%~dp0.."
%*
