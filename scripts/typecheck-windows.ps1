# Chequeo de TIPOS real del core y de sus pruebas con el compilador de Swift en Windows.
# No ejecuta nada compilado (en este equipo Defender/ASR bloquea ejecutar .exe nuevos, por lo que `swift build`/`swift test` no
# pueden correr: SwiftPM necesita ejecutar el manifiesto). Sirve para detectar errores de compilación, NO para ejecutar pruebas.
#   pwsh scripts/typecheck-windows.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$work = Join-Path $root '.swiftpm\typecheck'
New-Item -ItemType Directory -Force $work | Out-Null
$xctest = Join-Path $env:LOCALAPPDATA 'Programs\Swift\Platforms\6.4.2\Windows.platform\Developer\Library\XCTest-6.4.2\usr\lib\swift\windows'
$wrapper = Join-Path $PSScriptRoot 'swift-windows.cmd'

function Write-Rsp($path, $lines) { [System.IO.File]::WriteAllLines($path, $lines) }
$coreFiles = Get-ChildItem (Join-Path $root 'Sources\ViernesCore') -Filter *.swift | ForEach-Object { $_.FullName }
$testFiles = Get-ChildItem (Join-Path $root 'Tests\ViernesCoreTests') -Filter *.swift | ForEach-Object { $_.FullName }

Write-Host "[1/2] Core: emitir módulo (chequeo de tipos de $($coreFiles.Count) archivos)"
Write-Rsp "$work\core.rsp" (@('-emit-module', '-emit-module-path', "$work\ViernesCore.swiftmodule", '-module-name', 'ViernesCore',
    '-parse-as-library', '-swift-version', '5', '-enable-testing') + $coreFiles)
$out = cmd /c "`"$wrapper`" swiftc @$work\core.rsp 2>&1" | Out-String
$coreFail = $LASTEXITCODE -ne 0 -or $out -match 'error:'
$out = ($out -split "`n" | Where-Object { $_ -notmatch 'vswhere|programa o archivo por lotes' }) -join "`n"
if ($out.Trim()) { Write-Host $out }
Write-Host ("    => " + $(if ($coreFail) { 'ERRORES' } else { 'OK' }))

$testFail = $true
if (-not $coreFail) {
    Write-Host "[2/2] Pruebas: chequeo de tipos de $($testFiles.Count) archivos (XCTest)"
    Write-Rsp "$work\tests.rsp" (@('-typecheck', '-I', $work, '-I', $xctest, '-module-name', 'ViernesCoreTests', '-swift-version', '5') + $testFiles)
    $out2 = cmd /c "`"$wrapper`" swiftc @$work\tests.rsp 2>&1" | Out-String
    $testFail = $LASTEXITCODE -ne 0 -or $out2 -match 'error:'
    $out2 = ($out2 -split "`n" | Where-Object { $_ -notmatch 'vswhere|programa o archivo por lotes' }) -join "`n"
    if ($out2.Trim()) { Write-Host $out2 }
    Write-Host ("    => " + $(if ($testFail) { 'ERRORES' } else { 'OK' }))
}
if ($coreFail -or $testFail) { exit 1 }
