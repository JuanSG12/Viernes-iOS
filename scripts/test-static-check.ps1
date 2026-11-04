# Autoprueba del lexer de static-check.ps1: demuestra que detecta errores reales y no es una comprobación vacía.
$src = Get-Content (Join-Path $PSScriptRoot 'static-check.ps1') -Raw
$start = $src.IndexOf('function Test-SwiftBalance')
$end = $src.IndexOf('Write-Host "`n[1]')
. ([scriptblock]::Create($src.Substring($start, $end - $start)))

$tq = '"' * 3
$cases = [ordered]@{
    'bueno simple'           = @('func a() { let x = [1,2] }', $true)
    'bueno interpolacion'    = @('let s = "a \(b(c)) d"; func f() {}', $true)
    'bueno multilinea'       = @("let s = $tq`n  hola \(x) { `n$tq`nfunc f() {}", $true)
    'bueno llave en string'  = @('let s = "{ no cuenta"', $true)
    'bueno comentario'       = @("// { sin cerrar`nfunc f() {}", $true)
    'malo llave sin cerrar'  = @('func a() { let x = 1', $false)
    'malo cierre cruzado'    = @('func a() { (1 }', $false)
    'malo string sin cerrar' = @("let s = `"abc`nlet t = 1", $false)
    'malo interp sin cerrar' = @('let s = "a \(b d"', $false)
}
$bad = 0
foreach ($k in $cases.Keys) {
    $r = Test-SwiftBalance $cases[$k][0]
    $passed = (($null -eq $r) -eq $cases[$k][1])
    if (-not $passed) { $bad++ }
    '{0,-26} -> {1} ({2})' -f $k, $(if ($passed) { 'OK' } else { 'LEXER MAL' }), $(if ($r) { $r } else { 'sin error' })
}
if ($bad -gt 0) { exit 1 }
